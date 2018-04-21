require "./scoping"
require "./translation"
require "./relation_definition"

module Jennifer
  module Model
    abstract class Resource
      module ClassMethods
        abstract def table_name
        abstract def build(values, new_record : Bool)
      end

      extend Ifrit
      extend Translation
      extend ClassMethods
      include Scoping
      include RelationDefinition

      module ClassMethods
        abstract def relation(name)
      end

      extend ClassMethods

      alias Supportable = DBAny | self

      @@expression_builder : QueryBuilder::ExpressionBuilder?

      def inspect(io) : Nil
        {% begin %}
          {% if @type.constant("COLUMNS_METADATA") %}
            io << "#<" << {{@type.name.id.stringify}} << ":0x"
            object_id.to_s(16, io)
            io << ' '
            {% for var, i in @type.constant("COLUMNS_METADATA").keys %}
              {% if i > 0 %}
                io << ", "
              {% end %}
              io << "{{var.id}}: "
              @{{var.id}}.inspect(io)
            {% end %}
            io << '>'
            nil
          {% else %}
            super(io)
          {% end %}
        {% end %}
      end

      def self.build(values : Hash(Symbol, ::Jennifer::DBAny) | NamedTuple)
        o = new(values)
        o.__after_initialize_callback
        o
      end

      def self.build(values : Hash(String, ::Jennifer::DBAny))
        o = new(values)
        o.__after_initialize_callback
        o
      end

      def self.build(**values)
        o = new(values)
        o.__after_initialize_callback
        o
      end

      # Returns adapter instance.
      def self.adapter
        Adapter.adapter
      end

      def self.context
        @@expression_builder ||= QueryBuilder::ExpressionBuilder.new(table_name)
      end

      def self.all : QueryBuilder::ModelQuery(self)
        QueryBuilder::ModelQuery(self).build(table_name)
      end

      def self.where(&block)
        ac = all
        tree = with ac.expression_builder yield
        ac.set_tree(tree)
        ac
      end

      # Starts transaction.
      def self.transaction
        adapter.transaction do |t|
          yield(t)
        end
      end

      def self.search_by_sql(query : String, args = [] of Supportable)
        result = [] of self
        adapter.query(query, args) do |rs|
          rs.each do
            result << build(rs)
          end
        end
        result
      end

      def self.c(name : String)
        context.c(name)
      end

      def self.c(name : String | Symbol, relation)
        ::Jennifer::QueryBuilder::Criteria.new(name, table_name, relation)
      end

      def self.star
        context.star
      end

      def self.relation(name)
        raise Jennifer::UnknownRelation.new(self, name)
      end

      def append_relation(name : String, hash)
        raise Jennifer::UnknownRelation.new(self.class, name)
      end

      def set_inverse_of(name : String, object)
        raise Jennifer::UnknownRelation.new(self.class, name)
      end

      def get_relation(name : String)
        raise Jennifer::UnknownRelation.new(self.class, name)
      end

      abstract def attribute(name)
      abstract def primary
    end
  end
end
require "pg"
require "./base"

require "./postgres/result_set"
require "./postgres/exec_result"

require "./postgres/sql_generator"
require "./postgres/schema_processor"

require "./postgres/command_interface"

module Jennifer
  module Postgres
    class Adapter < Adapter::Base
      alias EnumType = Bytes

      TYPE_TRANSLATIONS = {
        :bool => "boolean",

        :integer => "int",      # Int32
        :short   => "SMALLINT", # Int16
        :bigint  => "BIGINT",   # Int64
        :oid     => "oid",      # UInt32

        :float  => "real",             # Float32
        :double => "double precision", # Float64

        :numeric => "numeric", # PG::Numeric
        :decimal => "decimal", # PG::Numeric - alias for numeric

        :string     => "varchar",
        :char       => "char", # String
        :text       => "text",
        :varchar    => "varchar",
        :blchar     => "blchar", # String

        :uuid => "uuid", # String

        :timestamp   => "timestamp", # Time
        :timestamptz => "timestamptz",
        :date_time   => "timestamp",
        :date        => "date",

        :bytea => "bytea", # Bytes

        :json  => "json",  # JSON
        :jsonb => "jsonb", # JSON
        :xml   => "xml",   # String

        :point   => "point", # PG::Geo::Point
        :lseg    => "lseg",
        :path    => "path",
        :box     => "box",
        :polygon => "polygon",
        :line    => "line",
        :circle  => "circle",
      }

      DEFAULT_SIZES = {
        :string     => 254
      }

      TABLE_LOCK_TYPES = {
        "as"      => "ACCESS SHARE",
        "rs"      => "ROW SHARE",
        "re"      => "ROW EXCLUSIVE",
        "sue"     => "SHARE UPDATE EXCLUSIVE",
        "s"       => "SHARE",
        "sre"     => "SHARE ROW EXCLUSIVE",
        "e"       => "EXCLUSIVE",
        "ae"      => "ACCESS EXCLUSIVE",
        "default" => "SHARE", # "s"
      }

      def sql_generator
        SQLGenerator
      end

      def self.command_interface
        @@command_interface ||= CommandInterface.new(Config.instance)
      end

      def self.default_max_bind_vars_count
        32766
      end

      def schema_processor
        @schema_processor ||= SchemaProcessor.new(self)
      end

      def translate_type(name)
        TYPE_TRANSLATIONS[name]
      rescue e : KeyError
        raise BaseException.new("Unknown data alias #{name}")
      end

      def default_type_size(name)
        DEFAULT_SIZES[name]?
      end

      def refresh_materialized_view(name)
        exec "REFRESH MATERIALIZED VIEW #{name}"
      end

      def table_column_count(table)
        if table_exists?(table)
          Query["information_schema.columns"].where { _table_name == table }.count
        elsif material_view_exists?(table)
          # materialized view
          Query["pg_attribute"]
            .join("pg_class") { _pg_attribute__attrelid == _oid }
            .join("pg_namespace") { _oid == _pg_class__relnamespace }
            .where do
              (_attnum > 0) &
                (_pg_namespace__nspname == Config.schema) &
                (_pg_class__relname == table) &
                _attisdropped.not
            end.count
        else
          -1
        end
      end

      def tables_column_count(tables : Array(String))
        view_request = Query["pg_attribute"]
          .join("pg_class") { _pg_attribute__attrelid == _oid }
          .join("pg_namespace") { _oid == _pg_class__relnamespace }
          .where do
            (_attnum > 0) &
              (_pg_namespace__nspname == Config.schema) &
              (_pg_class__relname.in(tables)) &
              _attisdropped.not
          end
          .group("table_name")
          .select { [_pg_class__relname.alias("table_name"), count.alias("count")] }

        Query["information_schema.columns"]
          .where { _table_name.in(tables) }
          .group(:table_name)
          .select { [_table_name, count.alias("count")] }
          .union(view_request)
          .to_a
      end

      def material_view_exists?(name)
        Query["pg_class"].join("pg_namespace") { _oid == _pg_class__relnamespace }.where do
          (_relkind == "m") &
            (_pg_namespace__nspname == Config.schema) &
            (_relname == name)
        end.exists?
      end

      def table_exists?(table)
        Query["information_schema.tables"]
          .where { _table_name == table }
          .exists?
      end

      def view_exists?(name) : Bool
        Query["information_schema.views"]
          .where { (_table_schema == Config.schema) & (_table_name == name) }
          .exists?
      end

      def column_exists?(table, name)
        Query["information_schema.columns"]
          .where { (_table_name == table) & (_column_name == name) }
          .exists?
      end

      def index_exists?(_table, name : String)
        Query["pg_class"]
          .join("pg_namespace") { _oid == _pg_class__relnamespace }
          .where { (_pg_class__relname == name) & (_pg_namespace__nspname == Config.schema) }
          .exists?
      end

      def foreign_key_exists?(from_table, to_table = nil, column = nil, name : String? = nil)
        name = self.class.foreign_key_name(from_table, to_table, column, name)
        Query["information_schema.table_constraints"]
          .where { and(_constraint_name == name, _table_schema == Config.schema) }
          .exists?
      end

      def enum_exists?(name)
        Query["pg_type"].where { _typname == name }.exists?
      end

      def enum_values(name)
        query_array("SELECT unnest(enum_range(NULL::#{name})::varchar[])", String).map { |array| array[0] }
      end

      def with_table_lock(table : String, type : String = "default", &block)
        transaction do |t|
          exec "LOCK TABLE #{table} IN #{TABLE_LOCK_TYPES[type]} MODE"
          yield t
        end
      rescue e : KeyError
        raise BaseException.new("Unknown table lock type '#{type}'.")
      end

      def upsert(obj : Model::Base, conflict : Array(String)? = nil, updates : Array(Array(String))? = nil)
        opts = obj.arguments_to_insert
        query_opts = parse_query(sql_generator.upsert(obj, obj.class.primary_auto_incrementable?, conflict, updates), opts[:args])

        id = -1i64
        affected = 0i64
        if obj.class.primary_auto_incrementable?
          query(*query_opts) do |x|
            x.each do
              id = x.read(Int32).to_i64
            end
          end
          affected += 1 if id > 0
        end

        obj.id = id.to_i.as(Primary32)

        ExecResult.new(id, affected)
      end

      def insert(obj : Model::Base)
        opts = obj.arguments_to_insert
        query_opts = parse_query(sql_generator.insert(obj, obj.class.primary_auto_incrementable?), opts[:args])
        id = -1i64
        affected = 0i64
        if obj.class.primary_auto_incrementable?
          id = scalar(*query_opts).as(Int).to_i64
          affected += 1 if id > 0
        else
          affected = exec(*query_opts).rows_affected
        end

        ExecResult.new(id, affected)
      end

      def exists?(query) : Bool
        scalar(*parse_query(sql_generator.exists(query), query.sql_args)).as(Bool)
      end

      def explain(q)
        body = sql_generator.explain(q)
        args = q.sql_args
        plan = ""
        query(*parse_query(body, args)) do |rs|
          rs.each do
            plan = rs.read(String)
          end
        end

        plan
      end

      private def extract_attributes(collection : Array, klass, fields : Array)
        enum_fields = [] of Tuple(Int32, Symbol)
        values = super

        klass.columns_tuple.each do |field, properties|
          if properties.has_key?(:converter) && properties.dig(:converter) == ::Jennifer::Model::EnumConverter
            enum_fields << {fields.index(field.to_s).not_nil!, field}
          end
        end

        unless enum_fields.empty?
          values.each_with_index do |row, row_index|
            enum_fields.each do |tuple|
              row[tuple[0]] = collection[row_index].attribute(tuple[1])
            end
          end
        end
        values
      end
    end
  end
end

require "./postgres/converters"
require "./postgres/criteria"
require "./postgres/numeric"
require "./postgres/migration/table_builder/base"
require "./postgres/migration/table_builder/*"

::Jennifer::Adapter.register_adapter("postgres", ::Jennifer::Postgres::Adapter)

module Jennifer
  class Connection
    @db : DB::Database?

    getter connected

    def initialize
      @connected = false
    end

    def checkout
      raise "you must connect first" unless @connected
      @db.not_nil!.checkout
    end

    def connect
      @db = DB.open(Adapter::Base.connection_string(:db))
      @connected = true
      @db
    end
  end
end

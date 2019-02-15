module Jennifer
  class Connection
    @conn : DB::Connection?

    getter connected

    def self.connect
      new.connect
    end

    def initialize
      @connected = false
    end

    def connect
      @conn = DB.connect(Adapter::Base.connection_string(:db))
      @connected = true
      @conn.not_nil!
    end
  end
end

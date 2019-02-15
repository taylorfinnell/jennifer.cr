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
      str = Adapter::Base.connection_string(:db)
      puts "DB STRINGG IS: #{str}"
      @conn = DB.connect(str)
      @connected = true
      @conn.not_nil!
    end
  end
end

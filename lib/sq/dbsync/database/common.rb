require 'sq/dbsync/tempfile_factory'

module Sq::Dbsync::Database
  module Common

    SQD = ::Sq::Dbsync

    def initialize(opts, source_or_target)
      db = Sequel.connect(opts)
      super(db)
      @db, @source_or_target = db, source_or_target
      @charset = opts[:charset] if opts[:charset]
    end

    def inspect
      "#<Database::#{self.class.name} #{source_or_target} #{opts[:database]}>"
    end

    def extract_to_file(table_name, columns, file_name)
      extract_sql_to_file("SELECT %s FROM %s" % [
        columns.join(', '),
        table_name
      ], file_name)
    end

    def extract_incrementally_to_file(plan, file_name, last_row_at, overlap)
      table_name = plan.source_table_name.to_sym
      db_columns = db.schema(table_name).map(&:first)

      query = self[table_name].select(*plan.columns)
      if last_row_at
        query = query.filter(
            "#{plan.timestamp} > ?",
            (plan.timestamp_in_millis ? ( (last_row_at.to_i - overlap) * 1000) : last_row_at - overlap))
      end

      sql = query.sql

      sql = customize_sql(sql, db.schema(table_name))

      extract_sql_to_file(sql, file_name)
    end

    def customize_sql(sql, schema)
      sql
    end

    def hash_schema(plan)
      ensure_connection
      Hash[schema(source? ? plan.source_table_name : plan.table_name)]
    end

    def source?
      source_or_target == :source
    end

    def name
      self['SELECT database()'].first.fetch(:'database()')
    end

    # Since we go so long without using connections (during a batch load), they
    # go stale and raise DatabaseDisconnectError when we try to use them. This
    # method ensures that the connection is fresh even after a long time
    # between drinks.
    def ensure_connection
      db.disconnect
    end

    def __getobj__
      db
    end

    def __setobj__(db)
      @db = db
    end

    protected

    attr_reader :db, :source_or_target, :charset

    def execute!(cmd)
      # psql doesn't return a non-zero error code when executing commands from
      # a file. The best way I can come up with is to raise if anything is
      # present on stderr.
      errors_file = SQD::TempfileFactory.make('extract_sql_to_file_errors')

      cmd = %{bash -c "#{cmd.gsub(/"/, '\\"')}"}

      result = run_shell(cmd, errors_file)

      unless result.exitstatus == 0 && File.size(errors_file.path) == 0
        raise(ExtractError, "Command failed: #{cmd}")
      end
    ensure
      errors_file.close! if errors_file
    end

    def sql_to_file(sql)
      SQD::TempfileFactory.make_with_content('extract_sql_to_file', sql)
    end

    private

    def run_shell(cmd, errors_file)
      if RUBY_PLATFORM == 'java'
        IO.popen4(cmd) {|_, _, _, stderr|
          errors_file.write(stderr.read)
          errors_file.flush
        }
        $?
      else
        pid = Process.spawn(cmd, STDERR => errors_file.path)
        Process.waitpid2(pid)[1]
      end
    end
  end
end

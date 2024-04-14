require "option_parser"

require "./generator"
require "./model"

module Wax::Generators
  module Subcommand
    macro define(name)
      abstract class {{name}}
        TYPES = {} of String => {{name}}.class

        getter type : String
        getter args : Array(String)

        def initialize(@type, @args)
        end

        def self.for(type_name : String)
          if type = TYPES[type_name]?
            type
          else
            raise ArgumentError.new("Unknown migration generator for type #{type_name.inspect}

Supported generators:#{TYPES.keys.map { |key| "\n- #{key}" }.join}")
          end
        end

        def self.with(args : Array(String))
          type, *args = args
          new(
            type: type,
            args: args,
          )
        end

        def self.handle(type : String)
          TYPES[type] = self
        end

        abstract def call

        {{yield}}
      end
    end
  end

  class Migration < Generator
    handle "migration"

    getter type : String
    getter args : Array(String)

    def self.description
      "Generate a database migration"
    end

    def self.new(args : Array(String))
      new(
        type: args[0],
        args: args[1..],
      )
    end

    def initialize(@type, @args)
    end

    Subcommand.define Type

    def call
      Type
        .for(type)
        .with(args)
        .call
    end

    class Add < Type
      handle "add"

      def call
        AddType
          .for(type)
          .with(args)
          .call
      end

      Subcommand.define AddType do
        include Commands

        def write_files(name : String, up : String, down : String)
          now = Time.utc
          timestamp = "%04d_%02d_%02d_%02d_%02d_%02d_%09d" % {
            now.year,
            now.month,
            now.day,
            now.hour,
            now.minute,
            now.second,
            now.nanosecond,
          }
          dir = "db/migrations/#{timestamp}-#{name}"

          file "#{dir}/up.sql", up
          file "#{dir}/down.sql", down
        end
      end

      class Column < AddType
        handle "column"

        def table_name
          type
        end

        def columns
          Model.new([table_name] + args).properties
        end

        def call
          up = String.build do |string|
            string.puts "ALTER TABLE #{table_name}"
            columns.each_with_index 1 do |property, index|
              string << "ADD COLUMN "
              property.to_sql string
              if index < columns.size
                string << ','
              end
              string.puts
            end
          end
          down = String.build do |string|
            string.puts "ALTER TABLE #{table_name}"
            columns.each_with_index 1 do |property, index|
              string << "DROP COLUMN #{property.name}"
              if index < columns.size
                string << ','
              end
              string.puts
            end
          end

          write_files "Add#{columns.map(&.name.camelcase(lower: false)).join}To#{table_name.camelcase(lower: false)}",
            up: up,
            down: down
        end
      end

      class Index < AddType
        handle "index"

        getter? unique = false
        getter? concurrently = false
        getter index_type : Type = :btree
        # getter op_class : String? = nil

        def initialize(type, args)
          super

          OptionParser.parse args do |parser|
            parser.banner = <<-EOF
              wax generate migration add index {table_name} {expression} [options]

              The `expression` can be:
              - a column name
                - name
                - account_id
              - multiple column names, comma-separated
                - name,account_id
                - "name, account_id" # note the quotes to count it as a single argument
              - an arbitrary SQL expression, wrapped in parentheses
                - '(lower(email))'

              EOF
            parser.on "-h", "--help", "Show help" do
              puts parser
              exit
            end
            parser.on "-u", "--unique", "Creates a unique index" do
              @unique = true
            end
            parser.on "-c", "--concurrently", "Creates the index concurrently" do
              @concurrently = true
            end
            type_names = Type.values.map(&.to_s).join(", ")
            parser.on "-t TYPE", "--type TYPE", "Use the specified index TYPE. Valid values are: #{type_names}" do |type_name|
              if index_type = Type.parse? type_name
                @index_type = index_type
              else
                raise ArgumentError.new "Invalid index type: #{type_name.inspect}. Valid values: #{type_names}"
              end
            end
          end
        end

        def call
          expression_name = expression
            .gsub(/\W+/, "_")
            .lchop('_')
            .split(',')
            .map(&.camelcase(lower: false))
            .join
          dir = "Index#{table_name.camelcase(lower: false)}On#{expression_name}"
          index_name = "index_#{table_name.underscore}_on_#{expression.gsub(/\W+/, '_').strip('_')}"
          up = String.build do |string|
            string << "CREATE "
            if unique?
              string << "UNIQUE "
            end
            string << "INDEX "
            if concurrently?
              string << "CONCURRENTLY "
            end
            string.puts index_name

            string.puts "ON #{table_name} USING #{index_type} (#{expression})"
          end
          down = String.build do |string|
            string << "DROP INDEX "
            if concurrently?
              string << "CONCURRENTLY "
            end
            string.puts index_name
          end

          write_files dir,
            up: up,
            down: down
        end

        def table_name
          type
        end

        def expression
          if expression = args.first?
            expression
          else
            raise ArgumentError.new "Missing index expression"
          end
        end

        enum Type
          BTREE
          GIN
          GIST
        end
      end
    end
  end
end

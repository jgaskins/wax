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

      Subcommand.define AddType

      class Column < AddType
        include Commands

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
          dir = "db/migrations/#{timestamp}-Add#{columns.map(&.name.camelcase(lower: false)).join}To#{table_name.camelcase(lower: false)}"
          file "#{dir}/up.sql", up
          file "#{dir}/down.sql", down
        end
      end
    end
  end
end

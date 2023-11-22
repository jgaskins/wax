require "./generator"

module Wax::Generators
  class Model < Generator
    handle "model"

    getter name : String
    getter properties : Array(Property)

    def self.description
      "Generate an Interro model type"
    end

    def self.new(properties : Array(String))
      type_name, *properties = properties

      properties = properties.map do |raw|
        components = raw.split(':')
        unless (name = components[0]?) && (type = components[1]?)
          STDERR.puts "Must supply property in the format `name:type` or `name:type:modifier1:modifier2:...`"
          exit 1
        end
        nullable = type.ends_with?("?")
        unique = components.includes?("unique")
        pkey = components.includes?("pkey")

        crystal_type = CRYSTAL_TYPE_MAP.fetch(type.rchop("?")) do |k|
          k.camelcase lower: false
        end

        sql_type = SQL_TYPE_MAP.fetch(type.rchop("?")) do |k|
          k.upcase
        end

        Property.new(
          name: name,
          crystal_type: crystal_type,
          sql_type: sql_type,
          nullable: nullable,
          unique: unique,
          primary_key: pkey,
        )
      end

      new type_name, properties
    end

    def initialize(@name, @properties)
    end

    def call
      model_file
      query_file
      migration_files
    end

    def query_file
      code = String.build do |string|
        string.puts %{require "./query"}
        string.puts
        string.puts "struct #{model_name}Query < Query(#{model_name})"
        string.puts %{  table "#{table_name}"}
        string.puts "end"
      end

      file "src/queries/#{name.underscore}.cr", code
    end

    def model_file
      code = String.build do |string|
        string.puts %{require "./model"}
        string.puts
        string.puts "struct #{model_name} < Model"
        properties.each do |property|
          string << "  getter #{property.name} : #{property.crystal_type}"
          if property.nullable?
            string << '?'
          end
          string.puts
        end

        string.puts "end"
      end

      file "src/models/#{name.underscore}.cr", code
    end

    def migration_files
      up = String.build do |string|
        string.puts "CREATE TABLE #{table_name}("
        properties.each_with_index 1 do |property, index|
          string << "  " << property
          if index < properties.size
            string << ','
          end
          string.puts
        end
        string.puts ")"
      end
      down = String.build do |string|
        string.puts "DROP TABLE #{table_name}"
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
      dir = "db/migrations/#{timestamp}-Create#{model_name}s"
      file "#{dir}/up.sql", up
      file "#{dir}/down.sql", down
    end

    def model_name
      name.camelcase(lower: false)
    end

    def table_name
      # TODO: Implement some sort of inflection
      "#{name.underscore}s"
    end

    private struct Property
      getter name : String
      getter crystal_type : String
      getter sql_type : String
      getter? nullable : Bool
      getter? unique : Bool
      getter? primary_key : Bool

      def initialize(@name, @crystal_type, @sql_type, @nullable, @unique, @primary_key)
      end

      def to_s(io) : Nil
        io << name << ' ' << sql_type

        if primary_key?
          io << " PRIMARY KEY"
        end

        if unique?
          io << " UNIQUE"
        end

        unless nullable?
          io << " NOT NULL"
        end
      end
    end

    private CRYSTAL_TYPE_MAP = {
      "uuid"     => "UUID",
      "password" => "BCrypt::Password",
    }

    private SQL_TYPE_MAP = {
      "password" => "TEXT",
      "string"   => "TEXT",
    }
  end
end

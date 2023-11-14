require "option_parser"
require "levenshtein"

module Wax
  class CLI
    enum Command
      Generate
      G
    end

    def self.call(args = ARGV)
      new.call args
    end

    def call(args = ARGV)
      OptionParser.parse args do |parser|
        parser.unknown_args do
          command_name, *subcommands = args
          case command = Command.parse?(command_name)
          in Nil
            STDERR.puts "Unknown command: #{command_name}"
            if possible_name = Levenshtein.find(command_name, Command.values.map(&.to_s.downcase))
              STDERR.puts "Did you mean `#{possible_name}`?"
            end
            exit 1
          in .generate?, .g?
            Generate.new(subcommands).call
          end
        end
      end
    end

    class Generate
      enum Type
        App
      end

      private SUBCOMMANDS = {
        Type::App => "Generates the entire application scaffold",
      }

      getter type : Type
      getter name : String = ""

      def self.new(args : Array(String))
        if (type = args.first?) && (type = Type.parse?(type))
          name = args.fetch(1, "")
          new type, name
        else
          STDERR.puts "What do you want to generate?"
          STDERR.puts
          size = SUBCOMMANDS.keys.max_by(&.to_s.size).to_s.size
          SUBCOMMANDS.each do |name, description|
            STDERR.puts "#{name.to_s.downcase.ljust size, ' '} - #{description}"
          end
          exit 1
        end
      end

      def initialize(@type, @name)
      end

      def call
        case type
        in .app?
          if name.empty?
            error "Must provide a name for the app"
          end
          app
        end
      end

      def error(message : String, exit_code code = 1)
        STDERR.puts message
        exit code
      end

      def app
        config
        queries
        models
        routes
        web
        views
        jobs
        dockerfile
      end

      def config
        file "src/config/config.cr", <<-EOF
          module Config
            macro define(name, &block)
              module ::Config
                class_getter {{name}} do
                  {{yield}}
                end
              end
            end
          end
          EOF
        env
        cache
        db
        sessions
        log
      end

      def env
        file "src/config/env.cr", <<-EOF
          require "wax/load"
          require "dotenv"
          Dotenv.load?
          EOF

        file ".env", <<-EOF
          DATABASE_URL="postgres:///#{@name.downcase}_dev"
          REDIS_URL="redis:///"
          EOF
      end

      def cache
        file "src/config/cache.cr", <<-EOF
          require "armature/cache"
          require "./config"
          require "./redis"

          Armature.cache = Armature::Cache::RedisStore.new(REDIS_CACHE)
          EOF
      end

      def db
        file "src/config/db.cr", <<-EOF
          require "./env"
          require "interro"

          Interro.config do |c|
            db = DB.open(ENV["DATABASE_URL"])
            c.write_db = db

            if replica_db_url = ENV["DATABASE_REPLICA_URL"]?
              replica_db = DB.open(replica_db_url)
              c.read_db = replica_db
            else
              c.read_db = db
            end

            [
              db,
              replica_db,
            ].compact.each &.setup_connection do |c|
              c.exec "SET statement_timeout = #{ENV.fetch("SQL_STATEMENT_TIMEOUT_MS", "10000")}"
            end
          end
          EOF
      end

      def sessions
        redis
        file "src/config/sessions.cr", <<-EOF
          require "armature/redis_session"

          require "./config"
          require "./redis"

          Config.define sessions : Armature::Session::RedisStore do
            Armature::Session::RedisStore.new(
              key: "#{@name.tr(" ", "_")}_session",
              redis: Config.redis,
              expiration: 365.days, # 1 year
            )
          end
          EOF
      end

      def redis
        file "src/config/redis.cr", <<-EOF
          require "redis"
          require "mosquito"
          
          require "./config"
          require "./env"

          Config.define redis : Redis::Client do
            Redis::Client.from_env("REDIS_URL")
          end

          Mosquito.configure do |settings|
            settings.redis_url = ENV["REDIS_URL"]
          end

          EOF
      end

      def log
        file "src/config/log.cr", <<-EOF
          require "log"

          require "./env"

          Log.setup_from_env
          EOF
      end

      def queries
        file "src/queries/query.cr", <<-EOF
          require "wax/load"
          src "config/db"
          src "queries/validations"

          abstract struct Query(T) < Interro::QueryBuilder(T)
            include Validations
          end
          EOF
        file "src/queries/validations.cr", <<-EOF
          module Validations
            struct Result(T)
              getter errors = [] of Error
              protected setter errors

              def validate_presence(**attributes) : self
                attributes.each do |attr, value|
                  # case value
                  # when String
                  unless value.presence
                    errors << Error.new(attr.to_s, "must not be blank")
                  end
                  # end
                end

                self
              end

              def validate_format(format, **attributes) : self
                attributes.each do |attr, value|
                  unless value =~ format
                    errors << Error.new(attr.to_s, "is in the wrong format")
                  end
                end

                self
              end

              def validate_format(name, value : String, format : Regex, *, failure_message : String = "#{name} is in the wrong format") : self
                unless value =~ format
                  errors << Error.new(name.to_s, failure_message)
                end

                self
              end

              def validate_size(name, value : String, unit : String, length : Range, failure_message = default_validate_size_failure_message(length, unit)) : self
                unless length.includes? value.size
                  errors << Error.new(name.to_s, failure_message)
                end

                self
              end

              private def default_validate_size_failure_message(length : Range, unit : String)
                case length
                when .finite?
                  range = "\#{length.min}-\#{length.max}"
                when .begin
                  range = "at least \#{length.min}"
                when .end
                  range = "at most \#{length.max}"
                end
                failure_message = "must be \#{range} \#{unit}"
              end

              def validate_uniqueness(attribute) : self
                if yield
                  errors << Error.new(attribute, "has already been taken")
                end

                self
              end

              def validate_uniqueness(*, message : String) : self
                if yield
                  errors << Error.new("", message)
                end

                self
              end

              def |(other : Result)
                result = self.class.new
                result.errors = errors | other.errors
              end

              def valid : Success(T) | Failure
                if errors.empty?
                  Success.new(yield)
                else
                  Failure.new(errors.sort_by(&.attribute))
                end
              end

              record Error, attribute : String, message : String do
                def to_s(io : IO)
                  unless attribute.empty?
                    io << attribute << ' '
                  end

                  io << message
                end
              end
            end

            record Success(T), object : T
            record Failure, errors : Array(Result::Error)
          end

          struct Range
            def finite?
              !!(self.begin && self.end)
            end
          end
          EOF

        file "src/queries/user.cr", <<-EOF
          require "./query"

          src "models/user"

          struct UserQuery < Query(User)
            table "users"

            def find(id : UUID)
              where(id: id).first?
            end

            def find_by(*, email : String)
              where(email: email).first?
            end

            def create(email : String, name : String, password : BCrypt::Password)
              result = Result(User).new
                .validate_presence(email: email, name: name)
                .validate_uniqueness("email") { where(email: email).any? }
                .valid do
                  insert email: email, name: name, password: password.to_s
                end
            end
          end
          EOF
      end

      def query(model, table)
        file "src/queries/#{model.underscore}.cr", <<-EOF
          require "./query"

          src "models/#{model.underscore}"

          struct #{model}Query < Query(#{model})
            table "#{table}"
          end
          EOF
      end

      def models
        file "src/models/model.cr", <<-EOF
          require "db"
          require "uuid"
          require "msgpack"

          abstract struct Model
            include DB::Serializable
            include MessagePack::Serializable
          end

          struct UUID
            def self.new(unpacker : MessagePack::Unpacker)
              new unpacker.read_bytes
            end

            def to_msgpack(packer : MessagePack::Packer)
              packer.write bytes.to_slice
            end
          end
          EOF

        file "src/models/user.cr", <<-EOF
          require "./model"

          src "bcrypt"

          struct User < Model
            getter id : UUID
            getter email : String
            getter name : String
            @[DB::Field(converter: BCrypt::Password)]
            getter password : BCrypt::Password
            getter created_at : Time
            getter updated_at : Time
          end
          EOF

        now = Time.utc
        time_string = "%04d_%02d_%02d_%02d_%02d_%02d_%09d" % [
          now.year,
          now.month,
          now.day,
          now.hour,
          now.minute,
          now.second,
          now.nanosecond,
        ]
        file "db/migrations/#{time_string}-CreateUsers/up.sql", <<-EOF
          CREATE TABLE users(
            id UUID PRIMARY KEY NOT NULL DEFAULT gen_random_uuid(),
            email TEXT UNIQUE NOT NULL,
            name TEXT NOT NULL,
            password TEXT NOT NULL,
            created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
          )
          EOF
        file "db/migrations/#{time_string}-CreateUsers/down.sql", <<-EOF
          DROP TABLE users
          EOF
      end

      private struct ModelProperty
        getter name : String
        getter type : String
        getter? nullable : Bool
        getter? unique : Bool

        def initialize(@name, @type, @nullable, @unique)
        end
      end

      private MODEL_TYPE_MAP = {
        "uuid" => "UUID",
        "password" => "BCrypt::Password",
      }
      def model(type_name, properties)
        properties = properties.map do |raw|
          components = raw.split(':')
          unless (name = components[0]?) && (type = components[1]?)
            STDERR.puts "Must supply property in the format `name:type` or `name:type:modifier1:modifier2:...`"
            exit 1
          end
          nullable = type.ends_with?("?")
          unique = components.includes?("unique")

          type = MODEL_TYPE_MAP.fetch(type) do |k|
            k.camelcase lower: false
          end

          ModelProperty.new(
            name: name,
            type: type,
            nullable: nullable,
            unique: unique,
          )
        end

        code = String.build do |string|
          string.puts %{require "./model"}
          string.puts
          string.puts "struct #{type_name.camelcase(lower: false)} < Model"
          properties.each do |property|
            string << "  getter #{property.name} : #{property.type}"
            if property.nullable?
              string << '?'
            end
            string.puts
          end

          string.puts "end"
        end

        file "src/models/#{type_name.underscore}.cr", code
      end

      def routes
        file "src/routes/route.cr", <<-EOF
          require "armature/route"
          require "armature/form"
          require "armature/cache"

          module Route
            include Armature::Route
            include Armature::Form::Helper
            include Armature::Cache

            # Add helper methods here
          end
          EOF
      end

      def web
        file "src/web.cr", <<-EOF
          require "http"
          require "wax/load"

          src "config/env"
          src "config/log"
          src "config/sessions"
          src "routes/web"

          log = Log.for("#{@name.downcase}.web")
          http = HTTP::Server.new([
            HTTP::LogHandler.new(log),
            HTTP::CompressHandler.new,
            HTTP::StaticFileHandler.new("public", directory_listing: false),
            Config.sessions,
            Web.new,
          ])

          # Shut down gracefully
          [
            Signal::INT,
            Signal::TERM,
          ].each(&.trap { http.close })

          port = ENV.fetch("PORT", "3200").to_i
          log.info &.emit "Listening for HTTP requests", port: port
          http.listen port
          EOF

        file "src/routes/web.cr", <<-EOF
          require "./route"

          src "queries/user"
          src "routes/home"
          src "routes/login"
          src "routes/signup"

          class Web
            include Route
            include HTTP::Handler

            def call(context)
              route context do |r, response, session|
                current_user = authenticate(session)

                response.headers["content-type"] = "text/html"
                render "app/header"

                r.root { Home.new.call context }

                r.on "signup" { Signup.new.call context }
                r.on "login" { Login.new.call context }

                if current_user
                  # Authenticated-only routes go here
                end

                # Add publicly available routes here

                r.miss do
                  response.status = :not_found
                  render "app/not_found"
                end

                render "app/footer"
              end
            end

            def authenticate(session)
              if (current_user_id = session["user_id"]?.try(&.as_s?)) && (current_user_id = UUID.parse?(current_user_id))
                UserQuery.new.find(current_user_id)
              end
            end
          end
          EOF

        file "src/routes/home.cr", <<-EOF
          require "./route"

          struct Home
            include Route

            def call(context)
              route context do |r, response, session|
                r.root { r.get { render "home/index" } }
              end
            end
          end
          EOF

        file "src/bcrypt.cr", <<-EOF
          require "crypto/bcrypt/password"

          alias BCrypt = Crypto::Bcrypt

          class BCrypt::Password
            def self.from_rs(rs : DB::ResultSet)
              new rs.read(String)
            end
          end
          EOF

        file "src/components/input.cr", <<-EOF
          require "armature/component"

          struct Input < Armature::Component
            getter name : String
            getter type : Type
            getter label : String
            getter id : String?
            getter? autofocus : Bool
            getter? required : Bool

            def initialize(
              @name,
              @type = :text,
              @label = name.capitalize,
              @id = nil,
              @autofocus = false,
              @required = false
            )
            end

            def_to_s "components/input"

            def attributes
              Attributes.new(
                name: name,
                type: type,
                id: id,
                autofocus: autofocus?,
                required: required?,
              )
            end

            enum Type
              TEXT
              EMAIL
              PASSWORD
              HIDDEN
              DATETIME_LOCAL

              def to_s(io)
                to_s.each_char do |ch|
                  case ch
                  when '_'
                    io << '-'
                  else
                    io << ch.downcase
                  end
                end
              end
            end

            struct Attributes(T)
              def self.new(**attrs)
                new attrs
              end

              def initialize(@attrs : T)
              end

              def to_s(io) : Nil
                @attrs.each do |key, value|
                  case value
                  when nil, false
                    # Do nothing
                  when true
                    io << ' ' << key.to_s
                  else
                    io << ' ' << key.to_s << '='
                    value.to_s io
                  end
                end
              end
            end
          end
          EOF

        view "components/input", <<-EOF
          <div>
            <label>
              <%= @label %>
              <input<%== attributes %>>
            </label>
          </div>
          EOF

        file "src/routes/signup.cr", <<-EOF
          require "./route"
          require "../bcrypt"
          require "../components/input"

          struct Signup
            include Route

            def initialize(*, @password_cost = 12)
            end

            def call(context)
              route context do |r, response, session|
                r.root do
                  r.get { render "signup/form" }
                  r.post do
                    params = r.form_params
                    if valid_authenticity_token?(params, session)
                      email = params["email"]? || ""
                      name = params["name"]? || ""
                      password = params["password"]? || ""

                      case result = UserQuery.new.create(email: email, name: name, password: BCrypt::Password.create(password, cost: @password_cost))
                      in Validations::Success(User)
                        session["user_id"] = result.object.id.to_s
                        response.redirect "/"
                      in Validations::Failure
                        response.status = :unprocessable_entity
                        errors = result.errors
                        render "signup/errors"
                        render "signup/form"
                      end
                    else
                      response.status = :bad_request
                      response << "bad request"
                    end
                  end
                end
              end
            end
          end
          EOF

        view "signup/errors", <<-EOF
          <style>
          #signup-errors {
            background: #fcc;
            color: red;
            border: 1px solid red;
            padding: 1em 1.25em;
            width: 800px;
            max-width: 100%;
            margin: 1em auto;
          }
          .signup-error {
          }
          </style>

          <ul id="signup-errors">
            <% errors.each do |error| %>
              <li class="signup-error">
                <%= error %>
              </li>
            <% end %>
          </ul>
          EOF

        view "signup/form", <<-EOF
          <% form method: "POST", id: "signup-form" do %>
            <%== Input.new name: "email", type: :email, id: "email" %>
            <%== Input.new name: "name", id: "name" %>
            <%== Input.new name: "password", type: :password, id: "password" %>

            <button id=sign-up>Sign up</button>
          <% end %>
          EOF

        file "src/routes/login.cr", <<-EOF
          require "./route"
          require "../bcrypt"
          require "../components/input"

          struct Login
            include Route

            def call(context)
              route context do |r, response, session|
                r.root do
                  r.get do
                    # Required variables for the form to be able to display login errors
                    # on POST.
                    error = nil
                    render "login/form"
                  end

                  r.post do
                    params = r.form_params
                    email = params["email"]?
                    password = params["password"]?

                    if email && password
                      if valid_authenticity_token?(params, session)
                        if (user = UserQuery.new.find_by(email: email)) && user.password.verify(password)
                          session["user_id"] = user.id.to_s
                          response.redirect "/"
                        else
                          response.status = :forbidden
                          error = "Invalid login"
                          render "login/form"
                        end
                      else
                        response.status = :bad_request
                        response << "bad request"
                      end
                    else
                      response.status = :bad_request
                      response << "Must supply login credentials"
                    end
                  end
                end
              end
            end
          end
          EOF

        view "login/form", <<-EOF
          <% if error %>
            <h3><%= error %></h3>
          <% end %>

          <% form method: "POST" do %>
            <%== Input.new name: "email", type: :email %>
            <%== Input.new name: "password", type: :password %>

            <button>Login</button>
          <% end %>
          EOF
      end

      def views
        view "app/header", <<-EOF
          <!doctype html>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1" />

          <header>
            <h1><a href="/">#{name}</a></h1>

            <nav>
              <% if current_user %>
                Logged in as <%= current_user.name %>
              <% else %>
                <a href="/login">Login</a>
                or
                <a href="/signup">sign up</a>
              <% end %>
            </nav>
          </header>

          <main>
          EOF
        view "app/footer", <<-EOF
          </main>

          <footer>
            <%# Footer content goes here %>
          </footer>
          EOF

        view "home/index", <<-EOF
          <h2>Homepage</h2>
          EOF

        view "app/not_found", <<-EOF
          <h2>Not Found</h2>
          EOF
      end

      def view(path, template)
        file "views/#{path}.ecr", template
      end

      def jobs
        file "src/worker.cr", <<-EOF
          require "./jobs/**"

          src "config/redis"

          Mosquito::Runner.start
          EOF

        file "src/jobs/job.cr", <<-EOF
          require "mosquito"
          require "wax/load"

          class Job < Mosquito::QueuedJob
          end
          EOF

        file "src/jobs/example.cr", <<-EOF
          require "./job"

          class ExampleJob < Job
            param something : String

            def perform
            end
          end
          EOF
      end

      def dockerfile
        file "Dockerfile", <<-EOF
          FROM 84codes/crystal:1.10.0-alpine AS builder

          COPY shard.yml shard.lock /app/
          WORKDIR /app
          ENV SHARDS_OPTS="--static"
          RUN shards install --jobs 8

          COPY src /app/src/
          COPY views /app/views/
          COPY db /app/db/
          RUN crystal build -o bin/web --static --release --stats --progress src/web.cr
          RUN crystal build -o bin/worker --static --release --stats --progress src/worker.cr

          # Deployable container
          FROM alpine

          RUN apk add --update --no-cache tzdata ca-certificates

          COPY --from=builder /app/bin/web /app/bin/worker /app/bin/interro-migration /app/bin/
          COPY --from=builder /app/db/ /app/db/
          WORKDIR /app

          CMD ["/app/bin/web"]
          EOF
      end

      def file(path, body)
        puts "Writing #{path}..."
        Dir.mkdir_p File.dirname(path)
        File.write path, body
      end
    end
  end
end

Wax::CLI.call

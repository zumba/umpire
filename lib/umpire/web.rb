require "sinatra/base"
require "rack/handler/mongrel"
require "rack-ssl-enforcer"
require "instruments"

module Umpire
  class Web < Sinatra::Base
    enable :dump_errors
    disable :show_exceptions
    use Rack::SslEnforcer if Config.force_https?
    register Sinatra::Instrumentation
    instrument_routes

    before do
      content_type :json
    end

    helpers do
      def protected!
        unless authorized?
          response["WWW-Authenticate"] = %(Basic realm="Restricted Area")
          throw(:halt, [401, JSON.dump({"error" => "not authorized"}) + "\n"])
        end
      end

      def authorized?
        @auth ||=  Rack::Auth::Basic::Request.new(request.env)
        if @auth.provided? && @auth.basic? && @auth.credentials
          if scope = Config.find_scope_by_key(@auth.credentials[1])
            log(scope: scope)
            true
          end
        end
      end

      def valid?(params)
        params["metric"] && (params["min"] || params["max"]) && params["range"]
      end

      def fetch_points(params)
        metric = params["metric"]
        source = params["source"]
        range = (params["range"] && params["range"].to_i)
        librato = params["backend"] == "librato"
        from = (params["from"] || LibratoMetrics::DEFAULT_FROM).to_sym
        compose = params["compose"]

        return Graphite.get_values_for_range(Config.graphite_url, metric, range) unless librato

        if !compose && metric.split(",").size > 1
          raise MetricNotComposite, "multiple metrics without a compose function"
        end

        return LibratoMetrics.compose_values_for_range(compose, metric.split(","), range, from, source) if compose
        LibratoMetrics.get_values_for_range(metric, range, from, source)
      end
    end

    get "/check" do
      protected!

      unless valid?(params)
        status 400
        next JSON.dump({"error" => "missing parameters"}) + "\n"
      end

      min = (params["min"] && params["min"].to_f)
      max = (params["max"] && params["max"].to_f)
      empty_ok = params["empty_ok"]

      begin
        points = fetch_points(params)
        if points.empty?
          status empty_ok ? 200 : 404
          JSON.dump({"error" => "no values for metric in range"}) + "\n"
        else
          value = (points.reduce { |a,b| a+b }) / points.size.to_f
          if ((min && (value < min)) || (max && (value > max)))
            status 500
          else
            status 200
          end
          JSON.dump({"value" => value}) + "\n"
        end
      rescue MetricNotComposite => e
        status 400
        JSON.dump("error" => e.message) + "\n"
      rescue MetricNotFound
        status 404
        JSON.dump({"error" => "metric not found"}) + "\n"
      rescue MetricServiceRequestFailed
        status 503
        JSON.dump({"error" => "connecting to backend metrics service failed with error 'request timed out'"}) + "\n"
      end
    end

    get "/health" do
      status 200
      JSON.dump({"health" => "ok"}) + "\n"
    end

   get "/*" do
     status 404
     JSON.dump({"error" => "not found"}) + "\n"
   end

    error do
      status 500
      JSON.dump({"error" => "internal server error"}) + "\n"
    end

    def self.start
      log(fn: "start", at: "build")
      @server = Mongrel::HttpServer.new("0.0.0.0", Config.port)
      @server.register("/", Rack::Handler::Mongrel.new(Web.new))

      log(fn: "start", at: "install_trap")
      Signal.trap("TERM") do
        log(fn: "trap")
        @server.stop(true)
        log(fn: "trap", at: "exit", status: 0)
        Kernel.exit!(0)
      end

      log(fn: "start", at: run, port: Config.port)
      @server.run.join
    end

    def log(data, &blk)
      Web.log(data, &blk)
    end

    def self.log(data, &blk)
      data.delete(:level)
      Log.log(Log.merge({ns: "web"}, data), &blk)
    end
  end
end

Instruments.defaults = {logger: Umpire::Web, method: :log}

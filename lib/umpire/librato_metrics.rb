module Umpire
  module LibratoMetrics
    extend self

    # Since we use summarize_sources => true ...
    # :value       == mean of means
    # :count       == mean of count
    # :min         == mean of min
    # :max         == mean of max
    # :sum         == mean of sum
    # :sum_squares == mean of sum_squares
    # :sum_means   == sum of means (aka values)
    # :summarized  == count of sources summarized
    DEFAULT_FROM = :value

    def get_values_for_range(metric, range, from, source=nil)
      begin
        start_time = Time.now.to_i - range

        options =  {
          :start_time => start_time,
          :summarize_sources => true
        }
        options.merge!(:source => source) if source

        results = client.fetch(metric, options)
        results.has_key?('all') ? results["all"].map { |h| h[from.to_s] } : []
      rescue Librato::Metrics::NotFound
        raise MetricNotFound
      rescue Librato::Metrics::NetworkError
        raise MetricServiceRequestFailed
      end
    end

    def compose_values_for_range(function, metrics, range, from, source=nil)
      raise MetricNotComposite, "too few metrics" if metrics.nil? || metrics.size < 2
      raise MetricNotComposite, "too many metrics" if metrics.size > 2

      composite = CompositeMetric.for(function)
      values = metrics.map { |m| get_values_for_range(m, range, from, source) }
      composite.new(*values).value
    end

    def client
      unless @client
        @client = ::Librato::Metrics::Client.new
        @client.authenticate Config.librato_email, Config.librato_key
      end
      @client
    end
  end
end

module CompositeMetric
  def self.for(function)
    case function
    when "sum"
      Sum
    when "divide"
      Division
    when "multiply"
      Multiplication
    else
      raise MetricNotComposite, "invalid compose function: #{function}"
    end
  end

  class Sum
    attr_reader :value

    def initialize(*values)
      first = values.shift
      @value = first.zip(*values).map do |items|
        items.inject(0) { |sum, i| sum += i }
      end
    end
  end

  class Division
    attr_reader :value

    def initialize(*values)
      @value = values[0].zip(values[1]).map do |v1, v2|
        v1.to_f / v2 unless v2.nil? || v2 == 0
      end.compact
    end
  end

  class Multiplication
    attr_reader :value

    def initialize(*values)
      @value = values[0].zip(values[1]).map do |v1, v2|
        v1 * v2 unless v2.nil?
      end.compact
    end
  end

end


require 'net/http'
require 'uri'
require 'parallel'
require 'concurrent'
require "benchmark"

debug = true

def show_help
    puts """
    This script benchmarks proxy requests and display an average.

    Usage:

      ruby #{__FILE__} URL QUANTITY CONCURRENCY [PROXY_LIST_FILE]
    """
end

if ARGV.count < 3
    show_help
    exit 1
end

# parse and validate url list file
raw_url = ARGV.shift
puts "raw url: #{raw_url.inspect}" if debug
url = URI.parse(raw_url)
if url.nil?
    STDERR.puts "Invalid url value \"#{url}\""
    exit 1
end

# parse and validate quantity param
raw_quantity = ARGV.shift
puts "raw quantity: #{raw_quantity.inspect}" if debug
quantity = Integer(raw_quantity)
puts quantity.inspect if debug
if quantity.nil?
    STDERR.puts "Invalid quantity value \"#{raw_quantity}\""
    exit 1
end
if quantity < 1
    STDERR.puts "Invalid quantity value #{quantity}, it must be greater or equal 1"
    exit 1
end

# parse and validate concurrency param
raw_concurrency = ARGV.shift
puts "raw concurrency: #{raw_concurrency.inspect}" if debug
concurrency = Integer(raw_concurrency)
if concurrency.nil?
    STDERR.puts "Invalid concurrency value \"#{raw_concurrency}\""
    exit 1
end
if concurrency < 1
    STDERR.puts "Invalid concurrency value #{concurrency}, it must be greater or equal 1"
    exit 1
end

# parse and validate proxy list file path
proxy_list_path = nil
raw_path = ARGV.shift
puts "raw proxy_list_path: #{raw_path.inspect}" if debug
unless raw_path.nil?
    unless File.exists?(raw_path)
        STDERR.puts "Proxy file \"#{raw_path}\" doesn't exist"
        exit 1
    end
    proxy_list_path = raw_path
end

# load proxy list file if exists
proxy_list = Concurrent::Array.new
unless proxy_list_path.nil?
    # read proxy file and load the proxy list
    f = File.open(proxy_list_path)
    f.each do |line|
        next if line.strip == ''
        line = "http://#{line}" unless line =~ /^http:\/\/.+/
        proxy_list << URI.parse(line)
    end
else
    # add a fake proxy when no proxy list was provided
    fake_proxy = Object.new
    fake_proxy.define_singleton_method(:host, lambda{nil})
    fake_proxy.define_singleton_method(:port, lambda{nil})
    fake_proxy.define_singleton_method(:schema, lambda{nil})
    fake_proxy.define_singleton_method(:user, lambda{nil})
    fake_proxy.define_singleton_method(:password, lambda{nil})
    proxy_list << fake_proxy
end

# run benchmark
semaphore = Mutex.new
sums = Concurrent::Array.new
Parallel.each(0..(concurrency-1), in_threads: concurrency) do |thread_index|
    puts "[T#{thread_index}]: Thread Index = #{thread_index}" if debug
    # calc limit
    target_uri = nil
    sums << {time: nil, count: 0}
    limit = 0
    semaphore.synchronize do
        target_uri = url.clone
        limit = (quantity.to_f / concurrency.to_f).floor
        puts "[T#{thread_index}]: Limit before = #{limit}" if debug
        adjustment = quantity - (limit * concurrency)
        puts "[T#{thread_index}]: Adjustment = #{adjustment}" if debug
        limit += 1 if adjustment > 0 && thread_index < adjustment
        puts "[T#{thread_index}]: Limit after = #{limit}" if debug
    end

    # perform test
    proxy_count = proxy_list.length
    limit.times do |index|
        proxy = proxy_list[rand(proxy_count)].clone
        proxy_address = proxy.host.nil? ? nil : "#{proxy.scheme}://#{proxy.host}"
        use_ssl = (target_uri.scheme =~ /https/)
        request = Net::HTTP::Get.new(target_uri)
        time = Benchmark.measure do
            Net::HTTP.start(target_uri.host, target_uri.port, proxy_address, proxy.port, proxy.user, proxy.password, use_ssl: use_ssl) do |http|
                http.request request do |response|
                    response.read_body do |chunk|
                        #puts chunk
                        # do nothing
                    end
                    puts "[T#{thread_index}]: Response status code = #{response.code}" if debug
                end
            end
        end
        puts "[T#{thread_index}]: Time: #{time}" if debug
        sums[thread_index][:time] = sums[thread_index][:time].nil? ? time : sums[thread_index][:time] + time
        sums[thread_index][:count] += 1
    end
end

puts "===============" if debug
puts "Expected quantity: #{quantity}" if debug
puts "Real quantity: #{sums.inject(0){|t, v|t += v[:count]}}" if debug

total = sums.inject(nil){|t, v|t = t.nil? ? v[:time] : t+v[:time]}
puts "Total time:   #{total}"
average = total / quantity
puts "Average time: #{average}"
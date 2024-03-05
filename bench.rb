require 'net/http'
require 'uri'
require 'parallel'
require 'concurrent'
require 'benchmark'
require 'ruby-progressbar'
require 'time'

DEFAULT_TIMEOUT = 2000

debug = false
debug_content = false

def show_help
    puts """
    This script benchmarks proxy requests and display an average.

    Usage:

      ruby #{__FILE__} URL QUANTITY CONCURRENCY [TIMEOUT=2000] [PROXY_LIST_FILE]
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

# validate quantity vs concurrency
if quantity < concurrency
    STDERR.puts "Can't set a higher concurrency than the quantity"
    exit 1
end

# parse and validate timeout param
raw_timeout = ARGV.shift
puts "raw timeout: #{raw_timeout.inspect}" if debug
timeout = Integer(raw_timeout)
if timeout.nil?
    timeout = DEFAULT_TIMEOUT
end
if timeout < 1
    STDERR.puts "Invalid timeout value #{timeout}, it must be greater or equal 1"
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
data = Concurrent::Array.new
progressbar = ProgressBar.create(total: quantity, length: 80, format: 'Progress %c/%C |%B| %a %e')
progressbar.total = quantity
Parallel.each(0..(concurrency-1), in_threads: concurrency) do |thread_index|
    puts "[T#{thread_index}]: Thread Index = #{thread_index}" if debug
    # calc limit
    target_uri = nil
    sums = {}
    limit = 0
    request_timeout = 0
    report_threshold = 0
    semaphore.synchronize do
        target_uri = url.clone
        limit = (quantity.to_f / concurrency.to_f).floor
        puts "[T#{thread_index}]: Limit before = #{limit}" if debug
        adjustment = quantity - (limit * concurrency)
        puts "[T#{thread_index}]: Adjustment = #{adjustment}" if debug
        limit += 1 if adjustment > 0 && thread_index < adjustment
        puts "[T#{thread_index}]: Limit after = #{limit}" if debug
        report_threshold = quantity / (concurrency * 20)
        report_threshold = 10 if report_threshold > 10
        request_timeout = timeout + 0
    end

    # perform test
    report_count = thread_index
    report_count_adjustment = thread_index
    report_time = Time.now.to_i
    proxy_count = proxy_list.length
    limit.times do |index|
        proxy = proxy_list[rand(proxy_count)].clone
        use_ssl = (target_uri.scheme =~ /https/)
        request = Net::HTTP::Get.new(target_uri)
        key = nil
        time = Benchmark.measure do
            begin
                Net::HTTP.start(target_uri.host, target_uri.port, proxy.host, proxy.port, proxy.user, proxy.password, use_ssl: use_ssl, verify_mode: OpenSSL::SSL::VERIFY_NONE, read_timeout: request_timeout) do |http|
                    http.request request do |response|
                        #puts response.inspect if debug
                        response.read_body do |chunk|
                            # show content only on debug
                            puts chunk if debug_content && debug
                        end
                        key = "#{response.code}"
                    end
                end
            rescue => ex
                STDERR.puts ex.inspect if debug
                key = "Failed"
            end
        end
        puts "[T#{thread_index}]: Response status code = #{key} | Time: #{time}" if debug

        # sum times depending on response code
        sums[key] = {time: Benchmark::Tms::new, count: 0, max: Benchmark::Tms::new, min: Benchmark::Tms::new} unless sums.has_key?(key)
        time_data = sums[key]
        time_data[:time] += time
        time_data[:count] += 1
        time_data[:max] = time if time_data[:max].total < time.total
        time_data[:min] = time if time_data[:min].total > time.total || time_data[:min].total <= 0

        # show progress as long as it's not on debug mode
        unless debug
            report_count += 1
            if report_count > report_threshold
                semaphore.synchronize do
                    progressbar.progress += report_count - report_count_adjustment
                end
                report_count = 0
                report_count_adjustment = 0
            end
        end
    end

    # show progress
    unless debug
        semaphore.synchronize do
            progressbar.progress += report_count
        end
    end
    data << sums
end

# join data
count = 0
total_time = Benchmark::Tms::new
total = {}
data.each do |sums|
    sums.each do |key, time_data|
        total[key] = {time: Benchmark::Tms::new, count: 0, max: Benchmark::Tms::new, min: Benchmark::Tms::new} unless total.has_key?(key)
        total_data = total[key]
        time = time_data[:time]
        total_data[:time] += time.clone
        total_data[:count] += time_data[:count]

        # calc min/max
        total_time += time
        max_time = time_data[:max]
        min_time = time_data[:min]
        total_data[:max] = max_time if total_data[:max].total < max_time.total
        total_data[:min] = min_time if total_data[:min].total > min_time.total || total_data[:min].total <= 0
        count += time_data[:count]
    end
end

puts ""
puts "===============" if debug
puts "Expected quantity: #{quantity}" if debug
puts "Real quantity: #{count}" if debug
puts "Total request time: #{total_time}"

# display time data per status code
total.to_a.sort{|a,b|a[0] <=> b[0]}.each do |key_pair|
    key, status_data = key_pair
    average = status_data[:time] / status_data[:count]
    puts ""
    puts "=========================="
    puts "Status code #{key}"
    puts "=========================="
    puts "Total requests: #{status_data[:count]}"
    puts "Total time:   #{status_data[:time]}"
    puts "--------------------------"
    puts "Max time:     #{status_data[:max]}"
    puts "Average time: #{average}"
    puts "Min time:     #{status_data[:min]}"
end

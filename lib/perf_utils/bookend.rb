require 'benchmark'
require 'objspace'
require 'singleton'
require 'logger'
require 'json'
require 'perf_utils/rack_storage'
require 'perf_utils/printer'


class Bookend
  class SimpleFormatter < Logger::Formatter
    def format_datetime(time)
      time.strftime("%H:%M:%S.%6N")
    end

    def call(severity, time, progname, msg)
      # #{format_datetime(time)}
      "#{msg2str(msg)}\n"
    end
  end

  include Singleton

  def _log
    @log_instance
  end

  def initialize
  end

  def self.track(name, &block)
    instance.track(name, &block)
  end
    base_url = options[:base_url] || "http://localhost:3000"
    # base_file = options[:base_file] || defined?(Rails) ? Rails.root.join("public") : "."
    env = {'RACK_MINI_PROFILER_ORIGINAL_SCRIPT_NAME' => base_url}

    page_struct = storage.current(env).page_struct
    start = Time.now
    #page_struct[:user] = config.user_provider.call(env) # needed?
    page_struct[:name] = name
    yield

    page_struct[:root].record_time((Time.now - start) * 1000)
#    storage.set_unviewed(page_struct[:user], page_struct[:id])
    storage.save(page_struct)
    page_struct[:id]
  ensure
    ::Rack::MiniProfiler.current = nil
  end

  def print(pages)
    pages = pages.map { |id| storage.load(id) }
    page_groups = pages.group_by { |page| page[:name] =~ /^(.*[^0-9])[0-9]+$/ ; $1 }.values
    printer.print_group(page_groups)
  end

  def printer
    @printer ||= ::PerfUtils::Printer.new.tap do |printer|
      printer.display_children = true
      printer.display_sql = true
    end
  end

  def storage
    @storage ||= ::PerfUtils::RackStorage.new
  end
end

def thrice(name, count = 1, &block)
  bookend("#{name}-0", &block)
  GC.start
  if count != 1
    4.times { |i| bookend("#{count if count != 1} #{name} #{i + 1}") { count.times(&block) } }
  else
    4.times { |j| bookend("#{count if count != 1} #{name} #{j + 1}", &block) }
  end
end

def bookend(name = "no name", count = 1, open_all = nil, &block)
  gen = false
  if open_all.to_s =~ /gen/
    open_all = false
    gen = true
  end
  gp = Bookend.instance
  x = count.times.collect do |i|
    #sand2("#{name}-#{i+1}", :normal, open_all.nil? ? i > 0 : open_all, &block)
    gp.capture("#{name}-#{i+1}", &block)
  end
  puts "beer gen_perf #{x}"
  gp.print(x) if gen
#  puts `gen_perf #{x}` if gen
  x
end

def sand2(name = "no name", mode = :normal, open_url = true, &block)
  options = {
    :open => open_url == true, :json => true, :html => true,
    :base_url => 'http://localhost:3000',
    :base_file => Rails.root.join("public")
  }
  Rack::MiniProfiler.new(block, {}).run_to_file(name, options, &block)
end

def sandprof(name = "no name", &block)
  data = ::RubyProf::Profile.profile do
    yield
  end
   # ::RubyProf::FlatPrinter => 'flat.txt',
   # ::RubyProf::GraphPrinter => 'graph.txt',
   # ::RubyProf::GraphHtmlPrinter => 'graph.html',
  printer = ::RubyProf::CallStackPrinter.new(data)
  file_name = Rails.join("tmp/profile/#{name}-#{Time.now.strftime("%H:%M:%S")}-call_stack.html")
  ::File.open(file_name, 'wb') do |file|
    printer.print(file, {})
  end
end

if false

Metric::Capture::perf_capture_timer
end

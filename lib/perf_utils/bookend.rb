require 'benchmark'
require 'objspace'
require 'singleton'
require 'logger'
require 'json'

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
    @log_instance = Logger.new(Rails.root.join("log").join("performance.log"))
    @log_instance.level = Logger::DEBUG
    @log_instance.formatter = ::Bookend::SimpleFormatter.new
  end

  def mark(message)
    _log.info(message)
  end

  def self.mark(*args)
    instance.mark(*args)
  end

  def self.track(name, &block)
    instance.track(name, &block)
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

def twosands(name = "no name", count = 2, open_all = nil, &block)
  gen = false
  if open_all.to_s =~ /gen/
    open_all = false
    gen = true
  end
  x = count.times.collect { |i| sand2("#{name}-#{i+1}", :normal, open_all.nil? ? i > 0 : open_all, &block) }.inspect
  puts "beer gen_perf #{x}"
  puts `gen_perf #{x}` if gen
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

Bookend.track("perf_capture_health_check") { Metric::Capture.perf_capture_health_check }
QueryCounter2.track { Metric::Capture.perf_capture_health_check }
bookend("perf_capture_health_check") do
  Metric::Capture.perf_capture_health_check
end
end

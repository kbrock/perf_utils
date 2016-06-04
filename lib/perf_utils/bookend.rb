require 'objspace'
require 'singleton'
require 'json'
require 'perf_utils/rack_storage'
require 'perf_utils/printer'

class Bookend
  include Singleton

  def initialize
  end

  def self.track(name, &block)
    instance.track(name, &block)
  end

  def capture(name, options = {})
    base_url = options[:base_url] || "http://localhost:3000"
    # base_file = options[:base_file] || defined?(Rails) ? Rails.root.join("public") : "."
    env = {'RACK_MINI_PROFILER_ORIGINAL_SCRIPT_NAME' => base_url}

    page_struct = storage.current(env).page_struct
    #page_struct[:user] = config.user_provider.call(env) # needed?
    page_struct[:name] = name
    d = PerfUtils::Stat.new(name).calc
    yield
    d.delta
    page_struct[:root].record_time(d.time * 1000)

#    storage.set_unviewed(page_struct[:user], page_struct[:id])
    storage.save(page_struct)
    [page_struct[:id], d]
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
  # [[gen_perf_num, stat]]
  xs = count.times.collect do |i|
    gp.capture("#{name}-#{i+1}", &block)
  end
  stats = xs.map(&:last)
  x = xs.map(&:first)
  if gen
    fs = stats.first
    puts
    puts fs.header
    puts fs.dash
    puts stats.collect(&:message)
    puts
    gp.print(x)
    puts
  else
    puts
    puts "beer gen_perf #{x}"
  end
  x
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

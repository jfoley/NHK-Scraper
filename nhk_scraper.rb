# coding: utf-8

require 'nokogiri'
require 'open-uri'
require 'uri'
require 'active_record'
require 'sqlite3'
require 'debugger'
require 'thread'

# http://burgestrand.se/code/ruby-thread-pool/
class Pool
  def initialize(size)
    @size = size
    @jobs = Queue.new
    @pool = Array.new(@size) do |i|
      Thread.new do
        Thread.current[:id] = i
        catch(:exit) do
          loop do
            job, args = @jobs.pop
            job.call(*args)
          end
        end
      end
    end
  end

  def schedule(*args, &block)
    @jobs << [block, args]
  end

  def shutdown
    @size.times do
      schedule { throw :exit }
    end
    @pool.map(&:join)
  end
end

class Show < ActiveRecord::Base
  has_many :episodes
end

class Episode < ActiveRecord::Base
  belongs_to :show
end

class NHKScraper
  DB_CONF = { :adapter => 'sqlite3', :database => 'nhk_shows.sqlite3' }
  LOG_FILE = "output.log"
  MAX_DOWNLOAD_THREADS = 3
  MAX_CONVERT_THREADS = 2
  ROOT_PATH = '高校講座'
  VLC_PATH = '/Applications/VLC.app/Contents/MacOS/VLC'

  def initialize
    @main_uri = URI.parse("http://www.nhk.or.jp/kokokoza/sitemap.html")
  end

  def load_database
    ActiveRecord::Base.establish_connection(DB_CONF)

    unless File.exists?(DB_CONF[:database])
      ActiveRecord::Schema.define do 
        create_table :shows do |t|
          t.string :name
          t.string :url
        end

        create_table :episodes do |t|
          t.string :name
          t.string :url
          t.string :video_url
          t.string :video_path
          t.integer :ep_number
          t.references :show
          t.boolean :downloaded, :default => false
          t.boolean :converted, :default => false
        end
      end

      puts ActiveRecord::Schema
    end
  end

  def get_shows
    return unless Show.count == 0

    puts "opening main URL"
    doc = Nokogiri::HTML(open(@main_uri))
    doc.css('.site_left_02').first.css('a').each {|node|
      url = node['href']
      name = node.text
      puts "url:#{url} name:#{name}"
      Show.create(:name => name, :url => url)
    }
  end

  def get_episodes
    return unless Episode.count == 0

    for show in Show.all
      puts "opening show URL"
      3.times do |x|
        season_url = @main_uri + URI.parse(show.url)
        if x == 0
          season_url += "index.html"
        else
          season_url += "index#{x + 1}.html"
        end
        doc = Nokogiri::HTML(open(season_url))
        puts "opened #{season_url}"

        doc.css('a').each {|node|
          if node['href'].match(/^.*archive.*html$/)
            url = season_url.to_s.gsub(/index.*$/, '') + node['href'][2..-1]
            name = node.css('span').text
            puts "url:#{url} name:#{name}"
            show.episodes.create(:url => url, :name => name, :ep_number => show.episodes.count + 1) if name != ''
          end
        }
      end
    end
  end

  def get_video_urls
    for episode in Episode.where(:video_url => nil).all
      doc = Nokogiri::HTML(open(episode.url))
      anchor_node = doc.css('#scd_naiyou_media a').first
      anchor_node = doc.css('#scd_naiyou_box a').first unless anchor_node

      video_url = anchor_node['href']

      puts "found video: #{video_url}"
      episode.update_attribute(:video_url, video_url)
    end
  end

  def create_directory_tree
    return if Dir.exists?(ROOT_PATH)

    Dir.mkdir(ROOT_PATH)
    for show in Show.all
      show_path = File.join(ROOT_PATH, show.name)
      Dir.mkdir(show_path)
    end
  end

  def download_shows
    pool = Pool.new(MAX_DOWNLOAD_THREADS)

    Episode.where(:downloaded => false).all.each do |episode|
      pool.schedule do
        video_file = "#{sprintf '%02d', episode.ep_number} - #{episode.name}.asf"
        puts "scheduling: #{video_file}\n"
        destination_path = File.join(ROOT_PATH, episode.show.name, video_file)
        File.delete(destination_path) if File.exists?(destination_path)
        vlc_command =  "#{VLC_PATH} -I dummy --sout='#transcode{vcodec=WMV2,vb=1024,acodec=a52,ab=192}:standard{mux=asf,dst=#{destination_path}},access=file}' #{episode.video_url} vlc://quit"
        puts "executing: #{vlc_command}\n"
        `#{vlc_command} &>#{LOG_FILE}`
        episode.update_attributes(:downloaded => true, :video_path => destination_path)
      end
    end

    unless Episode.where(:downloaded => false).exists?
      puts "all videos downloaded!"
    end

    pool.shutdown
  end

  def convert_shows
    pool = Pool.new(MAX_CONVERT_THREADS)

    Episode.where(:converted => false).all.each do |episode|
      pool.schedule do
        match = episode.video_path.match(/\/(.*)\/(\d{2}).*\.asf$/)
        next if match.nil?

        show_name = match[1]
        ep_number = match[2]

        input_file = episode.video_path
        basename = File.basename(episode.video_path, '.asf') + '.m4v' # remove the .asf and append .m4v
        output_file = File.join(File.dirname(episode.video_path), basename)

        handbrake_command = "HandbrakeCLI -i \"#{input_file}\" --preset=\"ipad\" -o \"#{output_file}\""
        puts "running handbrake command: #{handbrake_command}"
        `#{handbrake_command} &>#{LOG_FILE}`

        episode.update_attribute(:converted, true)
      end
    end

    pool.shutdown
  end

  def make_it_so
    load_database
    get_shows
    get_episodes
    get_video_urls

    create_directory_tree

    while Episode.where("downloaded = 'f' OR converted = 'f'").exists?
      recover
      download_shows
      convert_shows
    end
  end

  private
  def recover
    ids_to_download = []
    ids_to_reconvert = []

    Dir.glob( File.join(ROOT_PATH, '**', '*') ) do |file_path|
      if File.file?(file_path) && File.size(file_path) < 78643200
        match = file_path.match(/\/(.*)\/(\d{2}).*(asf|m4v)/)
        next if match.nil?

        show_name = match[1]
        ep_number = match[2]

        episode_ids = Episode.where(:ep_number => ep_number).joins(:show).where(:shows => {:name => show_name}).collect(&:id)

        if match[3] == 'asf'
          ids_to_download << episode_ids
        else
          ids_to_reconvert << episode_ids
        end

        File.delete(file_path)
      end
    end

    puts "ids to redownload: #{ids_to_download}"
    Episode.where(:id => ids_to_download).update_all(:downloaded => false)

    puts "ids to reconvert: #{ids_to_reconvert}"
    Episode.where(:id => ids_to_reconvert).update_all(:converted => false)
  end
end

if $0 == __FILE__
  scraper = NHKScraper.new
  scraper.make_it_so
end

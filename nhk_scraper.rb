# coding: utf-8

require 'nokogiri'
require 'open-uri'
require 'uri'
require 'active_record'
require 'sqlite3'
require 'ruby-debug'
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
  MAX_THREADS = 5
  ROOT_PATH = '高校講座'

  def initialize
    @main_uri = URI.parse("http://www.nhk.or.jp/kokokoza/library/index.html")
    @pool = Pool.new(MAX_THREADS)
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
          t.string :url # this is only the URL of the page the episode is displayed on
          t.string :video_url
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
    doc.css('a').each {|node|
      if node['href'].match(/^2010\/tv.*$/)
        url = node['href']
        name = node.css('img').first['alt']
        puts "url:#{url} name:#{name}"
        Show.create(:name => name, :url => url)
      end
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
            show.episodes.create(:url => url, :name => name, :ep_number => show.episodes.count + 1)
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
    return if Dir.exists?(ROOT_PATH) # its already here, bail out
    
    Dir.mkdir(ROOT_PATH)
    for show in Show.all
      show_path = File.join(ROOT_PATH, show.name)
      Dir.mkdir(show_path)
    end
  end

  def download_shows
    Episode.where(:downloaded => false).all.each do |episode|
      @pool.schedule do
        video_file = "#{sprintf '%02d', episode.ep_number} - #{episode.name}.asf"
        puts "scheduling: #{video_file}\n"
        destination_path = File.join(ROOT_PATH, episode.show.name, video_file)
        File.delete(destination_path) if File.exists?(destination_path)
        vlc_command =  "/Applications/VLC.app/Contents/MacOS/VLC -I dummy --sout='#transcode{vcodec=WMV2,vb=1024,acodec=a52,ab=192}:standard{mux=asf,dst=#{destination_path}},access=file}' #{episode.video_url} vlc://quit"
        puts "executing: #{vlc_command}\n"
        `#{vlc_command} &>#{LOG_FILE}`
        episode.update_attribute(:downloaded, true)
      end
    end

    unless Episode.where(:downloaded => false).exists?
      puts "all videos downloaded!"
    end
  end

  def shutdown
    @pool.shutdown
  end

  def recover
    rerun = false

    Dir.glob( File.join(ROOT_PATH, '**', '*') ) do |file_path|
      if File.file?(file_path) && File.size(file_path) < 78643200
        if episode_name = File.basename(file_path).match(/ - (.*)\.asf$/)
          episode = Episode.where(:name => episode_name[1]).first
          
          unless episode.nil?
            puts "marking episode as not downloaded: #{episode_name[1]}"
            episode.update_attribute(:downloaded, false)
            rerun = true
          else
            puts "WARNING: episode #{episode_name[1]} was not found"
          end
        end
        
      end
    end

    download_shows if rerun == true
  end

  def make_it_so
    load_database
    get_shows
    get_episodes
    get_video_urls

    create_directory_tree
    download_shows
    recover
  end
end

if $0 == __FILE__
  scraper = NHKScraper.new
  scraper.make_it_so

  at_exit { scraper.shutdown }
end

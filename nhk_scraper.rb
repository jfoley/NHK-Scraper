# coding: utf-8

require 'nokogiri'
require 'open-uri'
require 'uri'
require 'active_record'
require 'sqlite3'
require 'ruby-debug'
require 'thread'

class Show < ActiveRecord::Base
  has_many :episodes
end

class Episode < ActiveRecord::Base
  belongs_to :show
end

class NHKScraper
  DB_CONF = { :adapter => 'sqlite3', :database => 'nhk_shows.sqlite3' }
  LOG_FILE = "output.log"

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
          t.boolean :downloaded
          t.boolean :converted
        end
      end

      puts ActiveRecord::Schema
    end
  end

  def get_shows
    if Show.count == 0
      puts "opening main URL"
      #debugger
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
  end

  def get_episodes
    if Episode.count == 0
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
              show.episodes.create(:url => url, :name => name, :downloaded => false, :ep_number => show.episodes.count + 1)
            end
          }
        end
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

  def download_shows
    begin
      Dir.mkdir('高校講座')
    rescue Errno::EEXIST
      # keep going...
    end
    
    Dir.chdir('高校講座')

    for show in Show.all
      begin
        Dir.mkdir(show.name)
      rescue Errno::EEXIST
        # keep going...
      end

      Dir.chdir(show.name) do
        show.episodes.where(:downloaded => false).all.each do |episode|
          video_file = "#{sprintf '%02d', episode.ep_number} - #{episode.name}.asf"
          File.delete(video_file) if File.exists?(video_file)
          vlc_command =  "/Applications/VLC.app/Contents/MacOS/VLC -I dummy --sout='#transcode{vcodec=WMV2,vb=1024,acodec=a52,ab=192}:standard{mux=asf,dst=#{video_file}},access=file}' #{episode.video_url} vlc://quit"
          puts "executing: #{vlc_command}"
          `#{vlc_command} &>#{LOG_FILE}`
          episode.update_attribute(:downloaded, true)
        end
      end
    end
  end

  def main
    @main_uri = URI.parse("http://www.nhk.or.jp/kokokoza/library/index.html")
    load_database
    get_shows
    get_episodes
    get_video_urls

    download_shows
  end
end

if $0 == __FILE__
  scraper = NHKScraper.new
  scraper.main
end

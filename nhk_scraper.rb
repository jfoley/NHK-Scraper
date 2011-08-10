require 'nokogiri'
require 'open-uri'
require 'uri'

main_uri = URI.parse("http://www.nhk.or.jp/kokokoza/library/index.html")

puts "opening main URL"
doc = Nokogiri::HTML(open(main_uri))
puts = "main URL loaded #{doc}"

show_urls = []
doc.css('div.lby_text a').each do |link|
  puts link['href']
end

# video_uris = []
# doc.css('td.s_txt_lft a').each do |link|
#     video_uris.push(main_uri + URI.parse(link['href']))
# end

# media_uris = []
# video_uris.each do |uri|
#     doc = Nokogiri::HTML(open(uri))
#     media_uris.push doc.css('#scd_naiyou_media a').first['href']    
# end

# puts media_uris
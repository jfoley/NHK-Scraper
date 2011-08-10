videos = File.open('videos.txt', 'r').readlines

videos.each_index do |i|
  video_url = videos[i]
  puts "encoding video ##{i} #{video_url}"
  #command = "/Applications/VLC.app/Contents/MacOS/VLC #{video_url}  --stop-time=15 --sout '#transcode{vcodec=h264,venc=x264{profile=baseline,level=3.0,nocabac,nobframes,ref=1},deinterlace,vb=1560,scale=1,aspect=4:3,padd=true,vfilter=canvas{width=320,height=240},acodec=mp4a,ab=128,channels=2}:standard{mux=mp4,dst=#{Dir.getwd}/sekaishi_#{i}.mp4,access=file}' vlc://quit"
  #command = "/Applications/VLC.app/Contents/MacOS/VLC --stop-time=15 --sout='#transcode{vcodec=h264,vb=1024,scale=1,height=240,width=320,acodec=mp4a,ab=128,channels=2}:duplicate{dst=std{access=file,mux=mp4,dst=/Users/jfoley/Projects/nhk_scraper/sekaishi_#{i}.mp4}' #{video_url} :quit"
  #command = "/Applications/VLC.app/Contents/MacOS/VLC --stop-time=30 :sout=#transcode{vcodec=h264,vb=256,width=320,height=240,acodec=mp4a,channels=2,ab=128}:standard{mux=mp4,dst=/Users/jfoley/Projects/nhk_scraper/sekaishi_#{i}.mp4,access=file} #{video_url}"
  system "/Applications/VLC.app/Contents/MacOS/VLC -I dummy --run-time=1920 --sout='#transcode{vcodec=WMV2,vb=1024,acodec=a52,ab=192}:standard{mux=asf,dst=/Users/jfoley/Projects/nhk_scraper/sekaishi_#{i}.asf},access=file}' #{video_url} vlc:quit"
end

#!/bin/sh
set -eu

demo_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
render_dir="$demo_dir/.rendered"
mkdir -p "$render_dir"

for name in 01-controller 02-navigation 03-dictation 04-control-layer; do
  rsvg-convert -w 1280 -h 720 "$demo_dir/$name.svg" -o "$render_dir/$name.png"
done

ffmpeg -y -hide_banner -loglevel error -loop 1 -i "$render_dir/01-controller.png" -t 6.1 -vf "fade=t=in:st=0:d=0.35,fade=t=out:st=5.75:d=0.35,format=yuv420p" -r 30 "$render_dir/01.mp4"
ffmpeg -y -hide_banner -loglevel error -loop 1 -i "$render_dir/02-navigation.png" -t 6.4 -vf "fade=t=in:st=0:d=0.35,fade=t=out:st=6.05:d=0.35,format=yuv420p" -r 30 "$render_dir/02.mp4"
ffmpeg -y -hide_banner -loglevel error -loop 1 -i "$render_dir/03-dictation.png" -t 7.1 -vf "fade=t=in:st=0:d=0.35,fade=t=out:st=6.75:d=0.35,format=yuv420p" -r 30 "$render_dir/03.mp4"
ffmpeg -y -hide_banner -loglevel error -loop 1 -i "$render_dir/04-control-layer.png" -t 6.4 -vf "fade=t=in:st=0:d=0.35,fade=t=out:st=6.05:d=0.35,format=yuv420p" -r 30 "$render_dir/04.mp4"

printf "file '%s'\n" "$render_dir/01.mp4" "$render_dir/02.mp4" "$render_dir/03.mp4" "$render_dir/04.mp4" > "$render_dir/concat.txt"
ffmpeg -y -hide_banner -loglevel error -f concat -safe 0 -i "$render_dir/concat.txt" -c copy "$render_dir/video.mp4"
ffmpeg -y -hide_banner -loglevel error -i "$render_dir/video.mp4" -i "$demo_dir/ducky-access-voiceover.wav" -map 0:v:0 -map 1:a:0 -c:v libx264 -preset medium -crf 22 -pix_fmt yuv420p -c:a aac -b:a 128k -shortest -movflags +faststart "$demo_dir/ducky-access-demo.mp4"

echo "$demo_dir/ducky-access-demo.mp4"

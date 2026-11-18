# Makes the PNGs in static/ that can't be SVG: the iOS home-screen icon and the
# link-preview card. Run after `ruby build.rb` (the card uses the built 2023 chart),
# and commit the results. Needs rsvg-convert and Google Chrome; the build doesn't.
require "fileutils"
require "tmpdir"

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

# iOS rounds the corners itself, so the tile is square.
icon = File.read("static/favicon.svg").sub(' rx="7"', "")
Dir.mktmpdir do |dir|
  File.write("#{dir}/icon.svg", icon)
  system("rsvg-convert", "-w", "180", "-h", "180", "#{dir}/icon.svg", "-o", "static/apple-touch-icon.png", exception: true)

  page = File.read("site/2023/index.html")
  style = page[%r{<style>.*?</style>}m]
  chart = page[%r{<svg class="sankey sankey-w".*?</svg>}m]
  File.write("#{dir}/card.html", <<~HTML)
    <!doctype html>
    <meta charset="utf-8">
    #{style}
    <style>
      :root { color-scheme: light; }
      html, body { width: 1200px; height: 630px; margin: 0; overflow: hidden; }
      .card { display: flex; align-items: center; gap: 48px; height: 100%; padding: 0 56px; background: var(--bg); }
      .words { flex: 0 0 380px; }
      .kicker { font-size: 26px; font-weight: 600; letter-spacing: .12em; text-transform: uppercase; color: var(--muted); }
      h1 { margin: 10px 0 24px; font-size: 64px; line-height: 1.05; letter-spacing: -.01em; }
      p { margin: 0; font-size: 28px; line-height: 1.35; color: var(--muted); }
      .sankey { display: block; width: auto; height: 560px; }
      .sankey .hint { display: none; }
    </style>
    <div class="card">
      <div class="words">
        <div class="kicker">New Zealand MMP</div>
        <h1>Split-Vote Explorer</h1>
        <p>How voters split their party and electorate votes, 2017–2023</p>
      </div>
      #{chart}
    </div>
  HTML
  system(CHROME, "--headless", "--disable-gpu", "--hide-scrollbars", "--force-prefers-color-scheme=light",
         "--window-size=1200,630", "--screenshot=#{File.expand_path('static/og.png')}", "file://#{dir}/card.html",
         exception: true, err: File::NULL)
end
puts "Wrote static/apple-touch-icon.png and static/og.png"

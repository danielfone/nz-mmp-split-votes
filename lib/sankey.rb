require "cgi"

# A two-column Sankey drawn as static SVG. Nodes are drawn in the order given;
# each flow joins one left node to one right node. With no flows it draws the
# columns of bars on their own.
#
# Colours are CSS custom-property names (e.g. "national" -> var(--p-national)) so
# the page can restyle them for dark mode. A flow between two different colours
# is drawn as a gradient from one to the other.
module Sankey
  Node = Struct.new(:id, :label, :figure, :value, :paint, :aria, :y, :h, :label_y)
  Flow = Struct.new(:from, :to, :value, :from_paint, :to_paint, :faint)

  WIDTH = 600
  BAR = 12        # bar width
  GAP = 6         # vertical gap between bars
  LINE = 17       # minimum distance between label baselines
  HEIGHT = 460    # height available for bars

  module_function

  def render(left:, right:, flows:, label:)
    columns = [left, right].reject(&:empty?)
    # Both columns share one scale so a ribbon is the same thickness at each end.
    k = columns.map { |col| (HEIGHT - GAP * (col.size - 1)).to_f / col.sum(&:value) }.min
    columns.each { |col| stack(col, k) }
    height = columns.map { |col| [col.last.y + col.last.h, col.last.label_y + 6].max }.max

    <<~SVG
      <svg class="sankey" viewBox="0 0 #{WIDTH} #{height.ceil}" role="group" aria-label="#{h label}">
        <defs>
      #{gradients(flows).join("\n")}
        </defs>
        <g class="flows" aria-hidden="true">
      #{ribbons(left, right, flows, k).join("\n")}
        </g>
      #{left.map { |n| node(n, 0, :left) }.join("\n")}
      #{right.map { |n| node(n, WIDTH - BAR, :right) }.join("\n")}
      </svg>
    SVG
  end

  # Positions bars top to bottom, then nudges labels apart so they never overlap.
  def stack(col, k)
    y = 0.0
    col.each do |n|
      n.y = y
      n.h = n.value * k
      n.label_y = y + n.h / 2 + 5
      y += n.h + GAP
    end
    col.each_cons(2) { |a, b| b.label_y = [b.label_y, a.label_y + LINE].max }
  end

  # One horizontal gradient per colour pair, spanning the whole chart, shared by every ribbon with that pair.
  def gradients(flows)
    flows.map { |f| [f.from_paint, f.to_paint] }.uniq.reject { |a, b| a == b }.map do |a, b|
      %(    <linearGradient id="g-#{a}-#{b}" gradientUnits="userSpaceOnUse" x1="#{BAR}" x2="#{WIDTH - BAR}">) +
        %(<stop offset="0" style="stop-color:var(--p-#{a})"/><stop offset="1" style="stop-color:var(--p-#{b})"/></linearGradient>)
    end
  end

  def ribbons(left, right, flows, k)
    index = (left + right).each_with_index.map { |n, i| [n.id, i] }.to_h
    by_id = (left + right).map { |n| [n.id, n] }.to_h
    out_offset = Hash.new(0.0)
    in_offset = Hash.new(0.0)

    # Order ribbons at each end by the position of the node at the other end, so they don't cross needlessly.
    sources = flows.sort_by { |f| [index[f.from], index[f.to]] }
    starts = sources.map { |f| y = by_id[f.from].y + out_offset[f.from]; out_offset[f.from] += f.value * k; [f, y] }.to_h
    ends = flows.sort_by { |f| [index[f.to], index[f.from]] }
                .map { |f| y = by_id[f.to].y + in_offset[f.to]; in_offset[f.to] += f.value * k; [f, y] }.to_h

    x0 = BAR
    x1 = WIDTH - BAR
    xm = WIDTH / 2.0
    sources.map do |f|
      t = f.value * k
      y0 = starts[f]
      y1 = ends[f]
      d = "M#{x0},#{r y0}C#{xm},#{r y0} #{xm},#{r y1} #{x1},#{r y1}" \
          "V#{r y1 + t}C#{xm},#{r y1 + t} #{xm},#{r y0 + t} #{x0},#{r y0 + t}Z"
      fill = f.from_paint == f.to_paint ? "var(--p-#{f.from_paint})" : "url(#g-#{f.from_paint}-#{f.to_paint})"
      %(    <path class="f #{f.from} #{f.to}#{' same' if f.faint}" d="#{d}" style="fill:#{fill}"/>)
    end
  end

  def node(n, x, side)
    tx = side == :left ? x + BAR + 6 : x - 6
    anchor = side == :left ? "start" : "end"
    focus = n.aria ? %( tabindex="0" role="img" aria-label="#{h n.aria}") : %( aria-hidden="true")
    <<~NODE.chomp
      <g class="node" id="#{n.id}"#{focus}>
        <rect class="bar" x="#{x}" y="#{r n.y}" width="#{BAR}" height="#{r [n.h, 1].max}" style="fill:var(--p-#{n.paint})"/>
        <text x="#{tx}" y="#{r n.label_y}" text-anchor="#{anchor}"><tspan class="name">#{h n.label}</tspan> <tspan class="fig">#{h n.figure}</tspan></text>
      </g>
    NODE
  end

  def r(n)
    n.round(1)
  end

  def h(s)
    CGI.escapeHTML(s.to_s)
  end
end

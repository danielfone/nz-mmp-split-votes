# Builds the static site from data/ into site/.
#
#   ruby build.rb
require "csv"
require "erb"
require "fileutils"
require "set"
require_relative "lib/common"
require_relative "lib/sankey"

OUT = "site"
MAIN_SHARE = 0.02    # groups below this share are drawn as one "Other" node (the tables keep them all)
SPLIT_SHARE = 20     # a split cell is bold in the table if at least this % of the party's voters made it

def read(path)
  File.exist?(path) ? CSV.read(path, headers: true).map(&:to_h) : nil
end

def num(n)
  n.round.to_s.reverse.scan(/\d{1,3}/).join(",").reverse
end

def pct(part, whole, places = 1)
  format("%.#{places}f%%", 100.0 * part / whole)
end

def h(s)
  ERB::Util.h(s)
end

PARTIES = read("data/parties.csv").map { |r| [r["name"], r] }.to_h

def short(party)
  return "Independent" if party.to_s.empty?
  PARTIES.dig(party, "short") || party
end

# The CSS colour variable for a party: --p-<paint>.
def paint_for(party)
  PARTIES.key?(party) ? slugify(party) : "grey"
end

def palette_css
  light = PARTIES.map { |name, r| "--p-#{slugify(name)}: #{r['colour']};" } << "--p-grey: #9aa0a6;"
  dark = PARTIES.reject { |_, r| r["dark"].to_s.empty? }.map { |name, r| "--p-#{slugify(name)}: #{r['dark']};" } << "--p-grey: #7d848b;"
  [light.join(" "), dark.join(" ")]
end

# A short party code for chart labels, from parties.csv, or the party's initials.
def code(party)
  return "IND" if party.to_s.empty? || party == "Independent"
  return PARTIES[party]["code"] unless PARTIES.dig(party, "code").to_s.empty?
  words = party.scan(/[[:alnum:]]+/).reject { |w| %w[the of and party].include?(w.downcase) }
  (words.size > 1 ? words.map { |w| w[0] }.join : words.first.to_s)[0, 3].upcase
end

def page_path(year, slug)
  slug == "national" ? "/#{year}/" : "/#{year}/#{slug}/"
end

Party = Struct.new(:name, :votes, :cells) do
  def informal?
    name == INFORMAL_PARTY
  end

  def label
    informal? ? "Informal party vote" : short(name)
  end
end

Candidate = Struct.new(:name, :party, :votes) do
  def special?
    SPECIAL_COLUMNS.include?(name)
  end

  # A named candidate, as opposed to a category or a nationwide party column.
  def person?
    !special? && name != INDEPENDENTS && name != party
  end

  # Chart label: the surname as published and a party code, e.g. "GRIGG · NAT".
  def label
    person? ? "#{name.split(', ', 2).first} · #{code(party)}" : official
  end

  # A shorter chart label for narrow screens.
  def brief
    if name == INDEPENDENTS then "Independents"
    elsif name == NO_ELECTORATE_VOTE then "Port Waikato"
    else label
    end
  end

  # The official form, as published: "GRIGG, Nicola Anna (National Party)".
  def official
    if name == INFORMAL_CANDIDATE then "Informal"
    elsif name == PARTY_VOTE_ONLY then "Party vote only"
    elsif name == NO_ELECTORATE_VOTE then name
    elsif name == INDEPENDENTS then "Independents & others"
    elsif name == party then "#{short(party)} candidates" # nationwide: one column per party
    else "#{name} (#{party.to_s.empty? ? 'Independent' : party})"
    end
  end
end

Cell = Struct.new(:pct, :count)

# A node in the chart: one party or candidate, or several grouped as "Other".
Group = Struct.new(:label, :party, :members) do
  def votes
    members.sum(&:votes)
  end

  def paint
    party.to_s.empty? ? "grey" : paint_for(party)
  end

  def official
    members.size == 1 && members.first.respond_to?(:official) ? members.first.official : label
  end

  def brief
    return "Other" if label.start_with?("Other")
    members.first.respond_to?(:brief) ? members.first.brief : label
  end
end

class Result
  attr_reader :year, :status, :slug, :name, :type, :source, :note, :parties, :candidates

  def initialize(year:, status:, slug:, name:, type:, source:, note:, parties:, candidates:)
    @year, @status, @slug, @name, @type, @source, @note = year, status, slug, name, type, source, note
    @parties = parties.sort_by { |p| [p.informal? ? 1 : 0, -p.votes] }
    @candidates = candidates.sort_by { |c| [SPECIAL_COLUMNS.index(c.name) || (c.name == INDEPENDENTS ? -1 : -2), -c.votes] }
  end

  def self.from_rows(election, el, party_rows, flow_rows, candidate_rows)
    parties = party_rows.map { |r| Party.new(r["party"], Integer(r["votes"]), {}) }
    if flow_rows && flow_rows.any?
      candidates = flow_rows.map { |r| [r["candidate"], r["candidate_party"]] }.uniq.map { |n, p| Candidate.new(n, p, 0) }
      by_name = candidates.map { |c| [c.name, c] }.to_h
      party_by_name = parties.map { |p| [p.name, p] }.to_h
      flow_rows.each do |r|
        party = party_by_name.fetch(r["party"])
        cand = by_name.fetch(r["candidate"])
        cell = Cell.new(r["pct"], (party.votes * r["pct"].to_f / 100).round)
        party.cells[cand.name] = cell
        cand.votes += cell.count
      end
    else
      candidates = (candidate_rows || []).map { |r| Candidate.new(r["candidate"], r["party"], Integer(r["votes"])) }
    end
    new(year: election["year"], status: election["status"], slug: el["slug"], name: el["name"], type: el["type"],
        source: el["source"], note: el["note"], parties: parties, candidates: candidates)
  end

  # A nationwide result summed from electorate results (used when no national file is published).
  def self.aggregate(election, results)
    party_votes = Hash.new(0)
    cand_votes = Hash.new(0)
    results.each do |r|
      r.parties.each { |p| party_votes[p.name] += p.votes }
      r.candidates.each do |c|
        key = if c.special? then [c.name, nil]
              elsif c.party.to_s.empty? then [INDEPENDENTS, nil]
              else [c.party, c.party]
              end
        cand_votes[key] += c.votes
      end
    end
    new(year: election["year"], status: election["status"], slug: "national", name: "Nationwide", type: "national",
        source: election["source"], note: "Nationwide totals are the sum of the #{results.size} electorate results.",
        parties: party_votes.map { |n, v| Party.new(n, v, {}) },
        candidates: cand_votes.map { |(n, p), v| Candidate.new(n, p, v) })
  end

  def national?
    slug == "national"
  end

  def flows?
    @parties.any? { |p| p.cells.any? }
  end

  def title
    "#{name} #{year}"
  end

  def party_total
    @parties.sum(&:votes)
  end

  def candidate_total
    @candidates.sum(&:votes)
  end

  def count(party_members, cand_members)
    party_members.sum { |p| cand_members.sum { |c| (cell = p.cells[c.name]) ? cell.count : 0 } }
  end

  def right_groups
    @right_groups ||=
      if national?
        main, other = @candidates.partition { |c| !c.special? && c.name != INDEPENDENTS && c.votes >= MAIN_SHARE * candidate_total }
        main.map { |c| Group.new(c.label, c.party, [c]) } + (other.any? ? [Group.new("Other candidates & informal", nil, other)] : [])
      else
        @candidates.map { |c| Group.new(c.label, c.special? ? nil : c.party, [c]) }
      end
  end

  def left_groups
    @left_groups ||= begin
      main, other = @parties.partition { |p| !p.informal? && p.votes >= MAIN_SHARE * party_total }
      main = main.map { |p| Group.new(p.label, p.name, [p]) }
      if flows?
        # Order parties by the average position of their voters' candidates, which keeps ribbons from crossing.
        main = main.sort_by do |g|
          right_groups.each_with_index.sum { |rg, j| count(g.members, rg.members) * j }.to_f / g.votes
        end
      end
      main + (other.any? ? [Group.new("Other parties & informal", nil, other)] : [])
    end
  end

  def left_nodes
    @left_nodes ||= left_groups.each_with_index.map do |g, i|
      Sankey::Node.new("p#{i}", g.label, g.brief, g.votes, g.paint, flows? ? "#{g.label} party vote" : nil)
    end
  end

  def right_nodes
    @right_nodes ||= right_groups.each_with_index.map do |g, j|
      node = Sankey::Node.new("c#{j}", g.label, g.brief, g.votes, g.paint, flows? ? g.official : nil)
      node.upper = g.members.size == 1 && g.members.first.person? # published surnames are upper case
      node
    end
  end

  def nodes
    (left_nodes + right_nodes).each { |n| n.desc = "d-#{n.id}" if flows? }
  end

  def chart
    left, right = left_nodes, right_nodes
    flows = []
    if flows?
      left_groups.each_with_index do |lg, i|
        right_groups.each_with_index do |rg, j|
          c = count(lg.members, rg.members)
          next if c.zero?
          # Votes that stay with the same party, or go to informal/no candidate, are drawn faintly so splits stand out.
          faint = (lg.party && lg.party == rg.party) || rg.members.all?(&:special?)
          flows << Sankey::Flow.new("p#{i}", "c#{j}", c, lg.paint, rg.paint, faint)
        end
      end
    end

    # A wide chart, and a narrow one with shorter labels for phones; the page's CSS shows one.
    label = "#{title}: party votes on the left, electorate candidate votes on the right"
    hint = flows? ? "Select a bar for details" : nil
    Sankey.render(left: left, right: right, flows: flows, label: label, width: 600, prefix: "w", hint: hint) +
      Sankey.render(left: left, right: right, flows: flows, label: label, width: 360, prefix: "n", short: true, hint: hint)
  end

  # Table columns in row order, so each party's own candidate falls on a diagonal: candidates
  # whose party has a row, then everyone else by votes, then the categories.
  def table_candidates
    rank = @parties.each_with_index.map { |p, i| [p.name, i] }.to_h
    special, others = @candidates.partition(&:special?)
    matched, unmatched = others.partition { |c| rank.key?(c.party) }
    matched.sort_by { |c| [rank[c.party], -c.votes] } + unmatched + special
  end

  def split_flows
    @parties.reject(&:informal?).flat_map do |p|
      @candidates.reject { |c| c.special? || c.party == p.name }.map { |c| [p.cells[c.name] ? p.cells[c.name].count : 0, p, c] }
    end
  end

  # How a table cell is shaded: [:same, share] for a party's own candidate (the diagonal),
  # [:split, share] for another party's candidate, or nil (categories, zero, and parties
  # that had no candidate here, whose voters all had to split).
  def heat(party, cand)
    return nil if cand.special?
    @with_candidate ||= @candidates.reject(&:special?).map(&:party).to_set
    return nil unless @with_candidate.include?(party.name)
    share = party.cells[cand.name].pct.to_f
    return nil if share.zero?
    [cand.party == party.name ? :same : :split, share]
  end

  # How a split sentence names the candidate: "the Labour candidate", "National candidates".
  def split_target(cand)
    independent = cand.party.to_s.empty? || cand.party == "Independent"
    if national?
      cand.name == INDEPENDENTS ? "independent and other candidates" : "#{short(cand.party)} candidates"
    elsif independent
      others = @candidates.count { |c| c.person? && (c.party.to_s.empty? || c.party == "Independent") }
      others > 1 ? "the independent candidate #{cand.name.split(', ').first}" : "the independent candidate"
    else
      "the #{short(cand.party)} candidate"
    end
  end

  # What each chart node's votes did, shown when the node is selected.
  # Returns [id, heading, [[whole-number share, text], ...], whether smaller shares were left out].
  def descriptions
    return [] unless flows?
    counts = left_groups.map { |lg| right_groups.map { |rg| count(lg.members, rg.members) } }
    left = left_groups.each_with_index.map do |lg, i|
      rows = right_groups.each_with_index.map { |rg, j| [100.0 * counts[i][j] / lg.votes, chose(rg)] }
      ["p#{i}", voters_heading(lg), *listed(rows)]
    end
    right = right_groups.each_with_index.map do |rg, j|
      rows = left_groups.each_with_index.map { |lg, i| [100.0 * counts[i][j] / rg.votes, "from #{voters_from(lg)}"] }
      ["c#{j}", votes_heading(rg), *listed(rows)]
    end
    left + right
  end

  # Shares that round to at least 1%, largest first, and whether any smaller ones were left out.
  def listed(rows)
    rows = rows.each_with_index.sort_by { |(share, _), i| [-share, i] }.map(&:first) # stable, so ties keep their order on every Ruby
    shown = rows.select { |share, _| share.round >= 1 }
    [shown.map { |share, text| [share.round, text] }, rows.size > shown.size && rows.any? { |share, _| share > 0 && share.round < 1 }]
  end

  def voters_heading(lg)
    lg.label.start_with?("Other") ? "Voters for other parties, and informal party votes:" : "#{lg.label} party voters:"
  end

  def voters_from(lg)
    lg.label.start_with?("Other") ? "other parties' voters or informal party votes" : "#{lg.label} party voters"
  end

  def votes_heading(rg)
    return "Other candidates and informal votes:" if rg.label.start_with?("Other")
    c = rg.members.first
    case c.name
    when INFORMAL_CANDIDATE then "Informal electorate votes:"
    when PARTY_VOTE_ONLY then "Ballots with only a party vote:"
    when NO_ELECTORATE_VOTE then "Port Waikato party votes (no electorate vote):"
    when INDEPENDENTS then "Votes for independents and others:"
    when c.party then "Votes for #{short(c.party)} candidates:"
    else
      surname, given = c.name.split(", ", 2)
      "Votes for #{[given, surname].compact.join(' ')} (#{short(c.party)}):"
    end
  end

  def chose(rg)
    return "chose other candidates or voted informally" if rg.label.start_with?("Other")
    c = rg.members.first
    case c.name
    when INFORMAL_CANDIDATE then "cast an informal electorate vote"
    when PARTY_VOTE_ONLY then "cast only a party vote"
    when NO_ELECTORATE_VOTE then "were in Port Waikato, which had no electorate vote"
    else "chose #{split_target(c)}"
    end
  end

  # Party voters split three ways, as percentages of all party votes: those who chose their
  # own party's candidate, those who chose another (split), and the rest (informal votes,
  # party vote only, or no electorate vote).
  def vote_shares
    same = @parties.reject(&:informal?).sum do |p|
      @candidates.select { |c| !c.special? && c.party == p.name }.sum { |c| p.cells[c.name] ? p.cells[c.name].count : 0 }
    end
    split = split_flows.sum(&:first)
    shares = [same, split].map { |v| 100.0 * v / party_total }
    shares << 100 - shares.sum
  end

  def get_binding
    binding
  end
end

# ---- load ----

ELECTIONS = read("data/elections.csv")
RESULTS = {}
ELECTIONS.each do |e|
  dir = "data/#{e['year']}"
  party_votes = read("#{dir}/party_votes.csv")
  flows = read("#{dir}/flows.csv")
  candidates = read("#{dir}/candidates.csv")
  pick = ->(rows, slug) { rows && rows.select { |r| r["electorate"] == slug } }
  results = read("#{dir}/electorates.csv").map do |el|
    Result.from_rows(e, el, pick.(party_votes, el["slug"]), pick.(flows, el["slug"]), pick.(candidates, el["slug"]))
  end
  results << Result.aggregate(e, results) unless results.any?(&:national?)
  RESULTS[e["year"]] = results
end

# The previous and next elections as [year, href], or nil at either end. The href is
# nil where this place didn't exist that year.
def neighbours(result)
  i = ELECTIONS.index { |e| e["year"] == result.year }
  [i - 1, i + 1].map do |j|
    next nil unless j.between?(0, ELECTIONS.size - 1)
    y = ELECTIONS[j]["year"]
    [y, RESULTS[y].any? { |r| r.slug == result.slug } ? page_path(y, result.slug) : nil]
  end
end

# Sorted by slug so macrons sort with their base letter (Ōtaki among the Os).
def electorate_lists(year)
  RESULTS[year].reject(&:national?).sort_by(&:slug).group_by(&:type)
end

# ---- render ----

template = ERB.new(File.read("templates/page.html.erb"), trim_mode: "-")
FileUtils.rm_rf(OUT)
count = 0
RESULTS.each do |year, results|
  results.each do |result|
    path = "#{OUT}#{page_path(year, result.slug)}index.html"
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, template.result(result.get_binding))
    count += 1
  end
end

# The homepage is the nationwide page for the latest election with split votes.
home = RESULTS.values.reverse.flatten.find { |r| r.national? && r.flows? }
FileUtils.cp("#{OUT}#{page_path(home.year, 'national')}index.html", "#{OUT}/index.html")

puts "Built #{count} pages into #{OUT}/ (homepage: #{home.title})"

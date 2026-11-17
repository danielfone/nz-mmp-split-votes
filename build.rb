# Builds the static site from data/ into site/.
#
#   ruby build.rb
require "csv"
require "erb"
require "fileutils"
require_relative "lib/common"
require_relative "lib/sankey"

OUT = "site"
MAIN_SHARE = 0.02    # groups below this share are drawn as one "Other" node (the tables keep them all)
EXACT_BELOW = 10_000 # a percentage to 2 d.p. pins down a count exactly only when the row total is under this

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

Candidate = Struct.new(:name, :party, :votes, :approx) do
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
    if name == party then short(party)
    elsif name == INDEPENDENTS then "Independents"
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

  # How a party-vote breakdown refers to this column.
  def phrase
    case name
    when INFORMAL_CANDIDATE then "cast an informal candidate vote"
    when PARTY_VOTE_ONLY then "cast only a party vote"
    when NO_ELECTORATE_VOTE then "were in Port Waikato, where the electorate poll was cancelled"
    else "voted for #{official}"
    end
  end
end

Cell = Struct.new(:pct, :count, :exact)

# A node in the chart: one party or candidate, or several grouped as "Other".
Group = Struct.new(:label, :party, :members) do
  def votes
    members.sum(&:votes)
  end

  def paint
    party.to_s.empty? ? "grey" : paint_for(party)
  end

  def phrase
    members.size == 1 ? members.first.phrase : "voted for other candidates or informally"
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
      candidates = flow_rows.map { |r| [r["candidate"], r["candidate_party"]] }.uniq.map { |n, p| Candidate.new(n, p, 0, false) }
      by_name = candidates.map { |c| [c.name, c] }.to_h
      party_by_name = parties.map { |p| [p.name, p] }.to_h
      flow_rows.each do |r|
        party = party_by_name.fetch(r["party"])
        cand = by_name.fetch(r["candidate"])
        exact = party.votes < EXACT_BELOW
        cell = Cell.new(r["pct"], (party.votes * r["pct"].to_f / 100).round, exact)
        party.cells[cand.name] = cell
        cand.votes += cell.count
        cand.approx ||= !exact && cell.count > 0
      end
    else
      candidates = (candidate_rows || []).map { |r| Candidate.new(r["candidate"], r["party"], Integer(r["votes"]), false) }
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
        candidates: cand_votes.map { |(n, p), v| Candidate.new(n, p, v, false) })
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

  def where
    national? ? "voters nationwide" : "#{name} voters"
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

  # Sentence describing how one party's (or group's) voters cast their candidate vote.
  def party_sentence(label, members, columns)
    votes = members.sum(&:votes)
    parts = columns.map do |g|
      if members.size == 1 && g.members.size == 1
        cell = members.first.cells[g.members.first.name]
        next if cell.nil? || cell.pct.to_f.zero?
        [cell.pct.to_f, "#{cell.pct}% #{g.phrase}"]
      else
        c = count(members, g.members)
        next if c.zero?
        [100.0 * c / votes, "#{pct(c, votes, 2)} #{g.phrase}"]
      end
    end.compact.sort_by { |v, _| -v }.map(&:last)
    "#{label}: #{num votes} party votes. #{parts.join(', ')}."
  end

  def candidate_sentence(group)
    approx = group.members.any?(&:approx)
    parts = left_groups.map do |lg|
      c = count(lg.members, group.members)
      [c, "#{pct(c, group.votes)} from #{lg.label} party voters"] if c > 0
    end.compact.sort_by { |v, _| -v }.map(&:last)
    "#{group.official}: #{approx ? 'about ' : ''}#{num group.votes} votes. #{parts.join(', ')}."
  end

  def chart
    right = right_groups.each_with_index.map do |g, j|
      Sankey::Node.new("c#{j}", g.label, g.brief, pct(g.votes, candidate_total), g.votes, g.paint, flows? ? candidate_sentence(g) : nil)
    end
    left = left_groups.each_with_index.map do |g, i|
      Sankey::Node.new("p#{i}", g.label, g.brief, pct(g.votes, party_total), g.votes, g.paint,
                       flows? ? party_sentence(g.label, g.members, right_groups) : nil)
    end

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

    @nodes = left + right
    # A wide chart, and a narrow one with shorter labels for phones; the page's CSS shows one.
    label = "#{title}: party votes on the left, electorate candidate votes on the right"
    Sankey.render(left: left, right: right, flows: flows, label: label, width: 600, prefix: "w") +
      Sankey.render(left: left, right: right, flows: flows, label: label, width: 360, prefix: "n", short: true)
  end

  def nodes
    @nodes
  end

  def split_flows
    @parties.reject(&:informal?).flat_map do |p|
      @candidates.reject { |c| c.special? || c.party == p.name }.map { |c| [p.cells[c.name] ? p.cells[c.name].count : 0, p, c] }
    end
  end

  # The largest groups of voters who backed one party but a different party's candidate.
  def top_splits(n = 5)
    split_flows.select { |count, _, _| count > 0 }.sort_by { |count, _, _| -count }.first(n)
  end

  def split_share
    pct(split_flows.sum(&:first), party_total, 0)
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

# Each election year, with a link to the same place in that year (nil where it didn't exist).
def year_links(result)
  ELECTIONS.map do |e|
    y = e["year"]
    href = RESULTS[y].any? { |r| r.slug == result.slug } ? page_path(y, result.slug) : nil
    [y, e["status"], href]
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

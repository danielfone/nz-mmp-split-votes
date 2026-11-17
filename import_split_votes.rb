# Converts the Electoral Commission's split-vote CSVs for one election
# (data/raw/<year>/) into the tidy files the build reads (data/<year>/).
# Works for 2017, 2020 and 2023, which share a format. Only published values
# are written; counts are derived later, at build time.
#
#   ruby import_split_votes.rb 2023
require "csv"
require "fileutils"
require_relative "lib/common"

YEAR = ARGV.fetch(0) { abort "usage: ruby import_split_votes.rb <year>" }
RAW = "data/raw/#{YEAR}"
OUT = "data/#{YEAR}"
SOURCE = "https://www.electionresults.govt.nz/electionresults_#{YEAR}/statistics/csv/"

# The national file names two columns differently from the electorate files.
COLUMN_ALIASES = { "Candidate Informals" => INFORMAL_CANDIDATE }.freeze

# "GRIGG, Nicola Anna (National Party)" -> ["GRIGG, Nicola Anna", "National Party"].
# The party is the last bracketed group, found by matching brackets, because both
# names ("SMITH, Edward (Jack)") and parties ("The Opportunities Party (TOP)") can contain them.
def split_candidate(column)
  return [column, nil] unless column.end_with?(")")
  depth = 0
  (column.length - 1).downto(0) do |i|
    depth += 1 if column[i] == ")"
    depth -= 1 if column[i] == "("
    return [column[0...i].strip, column[i + 1...-1].strip] if depth.zero?
  end
  [column, nil]
end

electorates = []
party_votes = []
flows = []
any_cancelled = false

files = Dir["#{RAW}/split-votes-electorate-*.csv"].sort_by { |f| f[/\d+/].to_i } + ["#{RAW}/split-votes-all.csv"]
files.each do |path|
  rows = CSV.read(path, encoding: "bom|utf-8", row_sep: "\r\n") # a header cell can contain a bare \n
  header = rows.shift.map(&:strip)
  cancelled = false
  if header[0] == "All Electorates"
    slug, name, number, type = "national", "Nationwide", "", "national"
  else
    number, name = header[0].split(" ", 2)
    cancelled = name.include?("(Poll Cancelled)")
    any_cancelled ||= cancelled
    name = name.sub(/\s*\(Poll Cancelled\)/, "")
    slug, type = slugify(name), electorate_type(name)
  end
  note = cancelled ? "The electorate poll was cancelled after a candidate died, and the electorate vote was held as a by-election later. Only party votes are available." : nil
  electorates << [slug, name, number, type, SOURCE + File.basename(path), note]

  columns = header[2..-2].map { |c| COLUMN_ALIASES.fetch(c, c) } # everything between "Total Party Votes" and "Total %"
  columns << NO_ELECTORATE_VOTE if slug == "national" && any_cancelled
  rows.each do |row|
    party = row[0].strip
    next if party.start_with?("Total Party Votes")
    next if Integer(row[1]).zero? # a party with no votes in this electorate (e.g. HeartlandNZ 2020)

    party_votes << [slug, party, Integer(row[1])]
    next if cancelled

    pcts = row[2..-2]
    sum = pcts.map(&:to_f).sum
    if slug == "national" && any_cancelled
      # In 2023 Port Waikato's electorate poll was cancelled, so its party voters (about 1.5%)
      # have no candidate column in the national file. Keep them as an explicit remainder.
      pcts += [format("%.2f", 100 - sum)]
      sum = 100.0
    end
    warn "#{path}: #{party} percentages sum to #{sum.round(2)}" if (sum - 100).abs > 0.1

    columns.zip(pcts).each do |column, pct|
      if SPECIAL_COLUMNS.include?(column) || column == INDEPENDENTS
        candidate, candidate_party = column, nil                # informal, party vote only, independents
      elsif slug == "national"
        candidate, candidate_party = column, column             # national file: one column per party's candidates
      else
        candidate, candidate_party = split_candidate(column)    # electorate file: "GRIGG, Nicola Anna (National Party)"
      end
      flows << [slug, party, candidate, candidate_party, pct]
    end
  end
end

FileUtils.mkdir_p(OUT)
{ "electorates" => [%w[slug name number type source note], electorates],
  "party_votes" => [%w[electorate party votes], party_votes],
  "flows" => [%w[electorate party candidate candidate_party pct], flows] }.each do |file, (header, rows)|
  CSV.open("#{OUT}/#{file}.csv", "w") do |csv|
    csv << header
    rows.each { |r| csv << r }
  end
end

puts "#{YEAR}: #{electorates.size} results, #{flows.size} flows"

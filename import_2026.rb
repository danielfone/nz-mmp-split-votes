# Converts the 2026 preliminary-count electorate pages (data/raw/2026-preliminary/)
# into tidy files (data/2026/). Throwaway: replace with a CSV importer once the
# official results are published.
#
#   ruby import_2026.rb
require "csv"
require "cgi"
require_relative "lib/common"

RAW = "data/raw/2026-preliminary"
OUT = "data/2026"
SOURCE = "https://www.electionresults.govt.nz/electionresults_2026_preliminary/"

# One cell of the candidate/party table: a name and a vote count, either of which may be blank.
CELL = %r{<span data-sort-key="[^"]*">([^<]*)</span>\s*<span class="float-right" data-sort-key="[^"]*">([^<]*)</span>}m

def total(html, label)
  Integer(html[/#{label}:<\/label>\s*<span[^>]*>([\d,]+)</, 1].delete(","))
end

electorates = []
candidates = []
party_votes = []

Dir["#{RAW}/electorate-details-*.html"].sort.each do |path|
  html = File.read(path, encoding: "utf-8")
  name = CGI.unescapeHTML(html[%r{<h2>(.+?)\s+- Preliminary Count</h2>}, 1].strip)
  slug = slugify(name)
  electorates << [slug, name, File.basename(path)[/\d+/].to_i, electorate_type(name), SOURCE + File.basename(path)]

  # Each table row pairs a candidate (left) with their own party (right); either side may be empty.
  html.scan(%r{<tr>\s*<td>(.*?)</td>\s*<td>(.*?)</td>\s*</tr>}m).each do |left, right|
    cand, cand_votes = left.match(CELL)&.captures
    party, party_vote_count = right.match(CELL)&.captures
    next unless cand

    cand = CGI.unescapeHTML(cand.strip)
    party = CGI.unescapeHTML(party.to_s.strip)
    candidates << [slug, cand, party, Integer(cand_votes)] unless cand.empty?
    party_votes << [slug, party, Integer(party_vote_count)] unless party.empty?
  end
  candidates << [slug, INFORMAL_CANDIDATE, nil, total(html, "Candidate Informals")]
  party_votes << [slug, INFORMAL_PARTY, total(html, "Party Informals")]

  # Check against the page's own totals.
  cand_total, party_total = html.scan(%r{TOTAL:</label>\s*<span[^>]*>([\d,]+)<}).flatten.map { |n| Integer(n.delete(",")) }
  got_c = candidates.select { |r| r[0] == slug }.sum(&:last)
  got_p = party_votes.select { |r| r[0] == slug }.sum(&:last)
  warn "#{name}: candidate votes #{got_c} != page total #{cand_total}" unless got_c == cand_total
  warn "#{name}: party votes #{got_p} != page total #{party_total}" unless got_p == party_total
end

{ "electorates" => [%w[slug name number type source], electorates],
  "candidates" => [%w[electorate candidate party votes], candidates],
  "party_votes" => [%w[electorate party votes], party_votes] }.each do |file, (header, rows)|
  CSV.open("#{OUT}/#{file}.csv", "w") do |csv|
    csv << header
    rows.each { |r| csv << r }
  end
end

# Check the sum over electorates against the nationwide party votes on the overview page.
index = File.read("#{RAW}/index.html", encoding: "utf-8")
national = party_votes.group_by { |r| r[1] }.map { |p, rows| [p, rows.sum(&:last)] }.to_h
index.scan(%r{<td[^>]*>\s*([^<\d][^<]*?)\s*</td>\s*<td[^>]*>\s*([\d,]+)\s*</td>}m).each do |party, votes|
  party = CGI.unescapeHTML(party)
  next unless national.key?(party)
  published = Integer(votes.delete(","))
  warn "Nationwide #{party}: electorates sum to #{national[party]}, overview says #{published}" unless national[party] == published
end

puts "2026: #{electorates.size} electorates, #{candidates.size} candidate rows, #{party_votes.size} party rows"

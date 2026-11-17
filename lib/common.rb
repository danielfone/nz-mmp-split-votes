MAORI_ELECTORATES = [
  "Hauraki-Waikato", "Ikaroa-Rāwhiti", "Tāmaki Makaurau", "Te Tai Hauāuru",
  "Te Tai Tokerau", "Te Tai Tonga", "Waiariki"
].freeze

INFORMAL_PARTY = "Informal Party Votes"
INFORMAL_CANDIDATE = "Informal Candidate Votes"
PARTY_VOTE_ONLY = "Party Vote Only"
INDEPENDENTS = "Independents & parties with no list candidates"
NO_ELECTORATE_VOTE = "Port Waikato (no electorate vote)"
SPECIAL_COLUMNS = [INFORMAL_CANDIDATE, PARTY_VOTE_ONLY, NO_ELECTORATE_VOTE].freeze

# "Ōhāriu" -> "ohariu", "Panmure-Ōtāhuhu" -> "panmure-otahuhu"
def slugify(name)
  name.unicode_normalize(:nfkd).gsub(/\p{Mn}/, "").downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")
end

def electorate_type(name)
  MAORI_ELECTORATES.include?(name) ? "maori" : "general"
end

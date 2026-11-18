# New Zealand MMP Split-Vote Explorer

How New Zealand voters split their party vote and electorate vote, shown as a
static Sankey diagram for each election and electorate. No JavaScript: the chart is SVG
generated at build time, and highlighting uses CSS.

## Build

    for y in 2017 2020 2023; do ruby import_split_votes.rb $y; done   # data/raw/<y>/*.csv -> data/<y>/*.csv
    ruby import_2026.rb    # data/raw/2026-preliminary/*.html -> data/2026/*.csv
    ruby build.rb          # data/ -> site/
    python3 -m http.server 8123 --directory site

Plain Ruby standard library, no gems.

`static/` is copied into the site as is. Its PNGs (the iOS icon and the
link-preview card) are made by `ruby make_images.rb`, which needs
`rsvg-convert` and Google Chrome; rerun it after changing the favicon or party
colours, and commit the results.

## Data

- `data/raw/` holds the Electoral Commission's files unchanged.
- `data/<year>/` holds tidy CSVs containing only published values. Counts are
  derived from published percentages at build time.
- An election with `flows.csv` gets a Sankey; one without shows totals only.
- `data/parties.csv` sets each party's short name, chart code and
  colours (light and dark).

Election data © Electoral Commission New Zealand, from
[electionresults.govt.nz](https://www.electionresults.govt.nz/). Code is MIT
licensed (see `LICENSE`).

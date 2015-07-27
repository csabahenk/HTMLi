# HTMLi - a (non-compliant) HTML parser.

- pretty-indents html,
- converts html to/from nested array representation.

If used from command line:

- `$ htmli.rb`: indent HTML
- `$ htmli.rb collapse:2`: indent HTML, collapse deepest
   two tag levels into a single line
- `$ htmli.rb format:json`: dump a JSON representation
- `$ htmli.rb format:json:yajl`: dump a JSON representation using Yajl engine (handles some encodings issues better)
- `$ htmli.rb from:json`: convert from JSON representation to HTML

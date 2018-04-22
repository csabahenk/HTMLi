# HTMLi - a HTML parser (for some sense of HTML).

- pretty-indents html,
- converts html to/from JSON representation.

If used from command line:

- `$ htmli.rb`: indent HTML
- `$ htmli.rb --collapse 2`: indent HTML, collapse deepest
   two tag levels into a single line
- `$ htmli.rb --to json`: dump a JSON representation
- `$ htmli.rb --to json --layout nested`: dump an alternative JSON representation
- `$ htmli.rb --to json/yajl`: dump a JSON representation using Yajl engine (handles some encodings issues better)
- `$ htmli.rb --from json`: convert from JSON representation to HTML

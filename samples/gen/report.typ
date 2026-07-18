// report.typ — police-report template for the closure sample corpus.
// Embedded fonts (typst default: Libertinus/New Computer Modern) so pages
// render correctly through poppler / pdf_to_png on any machine.
//
// Content is passed as JSON via `--input data=<json>`; a document is a list of
// "sections", each a header + list of paragraphs. This keeps one template for
// both the single-page reports and the 100-page consolidated case file.

#let data = json(bytes(sys.inputs.data))

#set page(
  paper: "us-letter",
  margin: (x: 1in, y: 0.9in),
  header: context {
    set text(size: 8pt, fill: rgb("#555"))
    grid(
      columns: (1fr, 1fr),
      align(left)[RIVERTON POLICE DEPARTMENT],
      align(right)[CASE #data.case_no · CONFIDENTIAL],
    )
    line(length: 100%, stroke: 0.5pt + rgb("#bbb"))
  },
  footer: context {
    set text(size: 8pt, fill: rgb("#777"))
    grid(
      columns: (1fr, 1fr),
      align(left)[Criminal justice information — redaction review required (ORS 192.345)],
      align(right)[Page #counter(page).display() of #context counter(page).final().first()],
    )
  },
)
// hyphenate:false keeps tokens like SSNs and phone numbers from being split
// across lines, so pdf word-extraction (read_pdf_words) sees them intact.
#set text(font: "Libertinus Serif", size: 10.5pt, hyphenate: false)
#set par(justify: true, leading: 0.65em)

#align(center)[
  #text(size: 15pt, weight: "bold")[CITY OF RIVERTON POLICE DEPARTMENT]
  #v(2pt)
  #text(size: 12pt)[#data.title]
]

#v(6pt)
#block(fill: rgb("#f3f4f6"), inset: 8pt, radius: 3pt, width: 100%)[
  #grid(
    columns: (auto, 1fr),
    row-gutter: 3pt, column-gutter: 10pt,
    [*Case number*], [#data.case_no],
    [*Date of report*], [#data.date],
    [*Reporting officer*], [#data.officer],
    [*Classification*], [#data.classification],
  )
]

#v(8pt)

#for sec in data.sections [
  #if "newpage" in sec and sec.newpage [ #pagebreak() ]
  #text(size: 11pt, weight: "bold")[#sec.heading]
  #v(2pt)
  #for p in sec.paras [
    #par[#p]
    #v(4pt)
  ]
  #v(6pt)
]

#v(10pt)
#line(length: 100%, stroke: 0.5pt + rgb("#bbb"))
#text(size: 9pt)[
  *CERTIFICATION.* I certify under penalty of perjury that the foregoing report
  is true and accurate to the best of my knowledge and belief.
  #linebreak()
  Reporting officer: #data.officer · Case #data.case_no
]

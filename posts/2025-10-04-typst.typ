---
title: typst post
---

#set text(
  font: "New Computer Modern",
  size: 2pt
)

= Background
In the case of glaciers, fluid
dynamics principles can be used
to understand how the movement
and behaviour of the ice is
influenced by factors such as
temperature, pressure, and the
presence of other fluids (such as
water).

#align(center)[
  *A fluid dynamic model
  for glacier flow*
]


#grid(
  columns: (1.5em, 10fr, 10fr),
  align(center)[
    Therese Tungsten \
    Artos Institute \
    #link("mailto:tung@artos.edu")
  ],
  align(center)[
    Dr. John Doe \
    Artos Institute \
    #link("mailto:doe@artos.edu")
  ]
)

#align(center)[
  #set par(justify: false)
  *Abstract* \
  #lorem(80)
]

$
a + b &= c \
d &= e + f
$


$ A = pi r^2$

$ "area" = pi dot "radius"^2 $

$ sum_(k=0)^n k
    &= 1 + ... + n \
    &= (n(n+1)) / 2 $

With content.
#circle[
  #set align(center + horizon)
  Automatically \
  sized to fit.
]

#let ipa = [taɪpst]

The canonical way to
pronounce Typst is #ipa.

#table(
  columns: (1fr, 1fr),
  [Name], [Typst],
  [Pronunciation], ipa,
)

Einstein revolutionized physics @einstein1905.

Several foundational works exist [@knuth1984; @shannon1948].

#bibliography("../references.bib", title: "References", style: "springer-basic")

// #image("../images/imag.png")


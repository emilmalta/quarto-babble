# Babble Extension For Quarto

A Quarto extension that extracts translatable content from your documents and
generates language-specific templates. 

- Extracts all translatable content (headers, paragraphs, shortcode attributes, etc)
- Generates language-specific templates with key-value translation pairs
- Preserves document structure, while replacing content with Quarto shortcodes
- Produces .qmd files ready for translation


## Installing


```bash
quarto add emilmalta/quarto-babble
```

This will install the extension under the `_extensions` subdirectory.
If you're using version control, you will want to check in this directory.

## Using

Add the extension and your target languages in the front matter.

```yaml
filters:
  - babble
babble: 
  languages: [en, da, kl]
```

Render the document in the terminal:

```bash
quarto render myfile.qmd
```

This will:

- Extract all translatable text (paragraphs, headers, titles etc.) 
- Replace them with {{< meta langstrings.key >}} or t:key in shortcode parameters
- Create new called myfile.en.qmd, myfile.da.qmd etc.
- Add a `langstrings` block in each file, with keys and value placeholders

Edit the output files and fill in the translations:

```yaml
langstrings:
  title_header: "" # A Quarto report
  para_intro: "" This report shows ...
```

Leave the keys as-is, just translate in the quotes.

Render the output document for the final file.

```bash
quarto render myfile.en.qmd
```

## Example

Here is the source code for a minimal example: [example.qmd](example.qmd).


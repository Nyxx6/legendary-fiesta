import re # regular expressions
import os # operating system interfaces
import argparse # command-line argument parsing

# Sanitize a string to be safe for filenames
# Remove unsafe characters and replace spaces with underscores
def sanitize(name):
    name = name.strip()
    name = re.sub(r'[^\w\s-]', '', name)            # remove unsafe chars
    name = re.sub(r'[\s]+', '_', name)              # spaces -> underscore
    return name[:80]

# Split the text into sections based on the defined pattern
# Each section starts and ends with lines of 5 or more '=' characters
# followed by a title line
# Returns a list of (title, body) tuples
def split_sections(text):
    pattern = re.compile(r"(?m)^(?P<sep>={5,})\r?\n(?P<title>.+?)\r?\n={5,}\r?\n")
    matches = list(pattern.finditer(text))
    sections = []
    if not matches:
        return [("full_report", text)]
    for i, m in enumerate(matches):
        title = m.group("title").strip()
        start = m.end()
        end = matches[i+1].start() if i+1 < len(matches) else len(text)
        body = text[start:end].rstrip() + "\n"
        sections.append((title, body))
    return sections

# Main function to handle argument parsing and file operations
# Reads the input file, splits it into sections, and writes each section to a separate file
def main():
    p = argparse.ArgumentParser(description="Split audit file into section files")
    p.add_argument("input", help="path to audit .txt file")
    p.add_argument("-o", "--outdir", help="output directory", default=None)
    args = p.parse_args()

    with open(args.input, "r", encoding="utf-8", errors="ignore") as f:
        text = f.read()

    outdir = args.outdir or os.path.join(os.path.dirname(os.path.abspath(args.input)), "sections")
    os.makedirs(outdir, exist_ok=True)

    sections = split_sections(text)
    for idx, (title, body) in enumerate(sections, 1):
        fname = f"{idx:02d}_{sanitize(title)}.txt"
        path = os.path.join(outdir, fname)
        with open(path, "w", encoding="utf-8") as fo:
            # Write title then body
            fo.write(f"Title: {title}\n")
            fo.write(body)
    print(f"Wrote {len(sections)} files to {outdir}")

# Run the main function if this script is executed
# Command: python3 split_audit_sections.py audit_results.txt -o sections
if __name__ == "__main__":
    main()
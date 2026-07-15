"""Shared utilities for skill-creator scripts."""

from pathlib import Path


<<<<<<< HEAD
=======

>>>>>>> 2ecb89d (update)
def parse_skill_md(skill_path: Path) -> tuple[str, str, str]:
    """Parse a SKILL.md file, returning (name, description, full_content)."""
    content = (skill_path / "SKILL.md").read_text()
    lines = content.split("\n")

    if lines[0].strip() != "---":
        raise ValueError("SKILL.md missing frontmatter (no opening ---)")

    end_idx = None
    for i, line in enumerate(lines[1:], start=1):
        if line.strip() == "---":
            end_idx = i
            break

    if end_idx is None:
        raise ValueError("SKILL.md missing frontmatter (no closing ---)")

    name = ""
    description = ""
    frontmatter_lines = lines[1:end_idx]
    i = 0
    while i < len(frontmatter_lines):
        line = frontmatter_lines[i]
        if line.startswith("name:"):
<<<<<<< HEAD
            name = line[len("name:") :].strip().strip('"').strip("'")
        elif line.startswith("description:"):
            value = line[len("description:") :].strip()
=======
            name = line[len("name:"):].strip().strip('"').strip("'")
        elif line.startswith("description:"):
            value = line[len("description:"):].strip()
>>>>>>> 2ecb89d (update)
            # Handle YAML multiline indicators (>, |, >-, |-)
            if value in (">", "|", ">-", "|-"):
                continuation_lines: list[str] = []
                i += 1
<<<<<<< HEAD
                while i < len(frontmatter_lines) and (
                    frontmatter_lines[i].startswith("  ") or frontmatter_lines[i].startswith("\t")
                ):
=======
                while i < len(frontmatter_lines) and (frontmatter_lines[i].startswith("  ") or frontmatter_lines[i].startswith("\t")):
>>>>>>> 2ecb89d (update)
                    continuation_lines.append(frontmatter_lines[i].strip())
                    i += 1
                description = " ".join(continuation_lines)
                continue
<<<<<<< HEAD
            description = value.strip('"').strip("'")
=======
            else:
                description = value.strip('"').strip("'")
>>>>>>> 2ecb89d (update)
        i += 1

    return name, description, content

#!/usr/bin/env python3
import re
import sys
from pathlib import Path

OPENELIS_DIR = Path(__file__).resolve().parent
WEB_INF_DIR = OPENELIS_DIR / "run-bahmni-lab-bahmni-lab-WEB-INF-classes"
SET_OF_LANGUAGES_PATH = WEB_INF_DIR / "SetOfSupportedLanguages.properties"
BANNER_PATH = OPENELIS_DIR / "run-bahmni-lab-bahmni-lab-pages-common" / "banner.jsp"

CONFIRMATION_KEY_BY_LOCALE = {
    "en_US": "english",
    "fr-FR": "french",
    "es-ES": "spanish",
    "pt-BR": "portuguese",
    "ro-RO": "romanian",
}

DEFAULT_CONFIRMATION_MESSAGE = "Changing the language will affect all logged in users"


def read_lines(path: Path):
    data = path.read_bytes()
    newline = "\r\n" if b"\r\n" in data else "\n"
    text = data.decode("utf-8", errors="replace")
    lines = text.splitlines()
    has_trailing_newline = data.endswith(b"\n")
    return lines, newline, has_trailing_newline


def write_lines(path: Path, lines, newline, has_trailing_newline):
    text = newline.join(lines)
    if has_trailing_newline:
        text += newline
    path.write_text(text, encoding="utf-8")


def parse_properties(lines):
    data = {}
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("#") or line.startswith("!"):
            continue
        sep = "=" if "=" in line else (":" if ":" in line else None)
        if not sep:
            continue
        key, value = line.split(sep, 1)
        data[key.strip()] = value.lstrip()
    return data


def escape_properties_value(value: str) -> str:
    out = []
    for ch in value:
        if ord(ch) < 128:
            out.append(ch)
        else:
            out.append("\\u%04X" % ord(ch))
    return "".join(out)


def prompt_value(prompt: str, default: str) -> str:
    suffix = f" [{default}] " if default else " "
    value = input(f"{prompt}{suffix}").strip()
    return value if value else default


def list_locale_suffixes(prefix: str):
    locales = set()
    for path in WEB_INF_DIR.glob(f"{prefix}*.properties"):
        suffix = path.stem[len(prefix) :]
        if suffix:
            locales.add(suffix)
    return locales


def normalize_locale_tag(suffix: str) -> str:
    parts = [p for p in re.split(r"[-_]", suffix) if p]
    if not parts:
        return suffix
    language = parts[0].lower()
    if len(parts) == 1:
        region = language.upper()
        return f"{language}-{region}"
    normalized = [language]
    for part in parts[1:]:
        if len(part) == 4:
            normalized.append(part.title())
        else:
            normalized.append(part.upper())
    return "-".join(normalized)


def discover_locale_tags():
    message_locales = list_locale_suffixes("MessageResources_")
    bahmni_locales = list_locale_suffixes("BahmniMessageResources_")
    common = message_locales & bahmni_locales
    missing = message_locales ^ bahmni_locales
    if missing:
        missing_list = ", ".join(sorted(missing))
        print(
            f"Skipping incomplete locales (missing a matching resource file): {missing_list}",
            file=sys.stderr,
        )
    return sorted({normalize_locale_tag(locale) for locale in common})


def resolve_confirmation_key(locale_tag: str, props):
    if locale_tag in CONFIRMATION_KEY_BY_LOCALE:
        mapped = (
            f"languageConfirmation.message.{CONFIRMATION_KEY_BY_LOCALE[locale_tag]}"
        )
        if mapped in props:
            return mapped
    derived = f"languageConfirmation.message.{locale_tag.lower().replace('-', '_')}"
    if derived in props:
        return derived
    if locale_tag in CONFIRMATION_KEY_BY_LOCALE:
        return f"languageConfirmation.message.{CONFIRMATION_KEY_BY_LOCALE[locale_tag]}"
    return derived


def update_set_of_languages(locale_tags):
    lines, newline, has_trailing_newline = read_lines(SET_OF_LANGUAGES_PATH)
    props = parse_properties(lines)

    english_message = props.get(
        "languageConfirmation.message.english", DEFAULT_CONFIRMATION_MESSAGE
    )

    update_marker = None
    for idx, line in enumerate(lines):
        if line.strip() == "#Update message for each language":
            update_marker = idx
            break

    added_locales = []
    added_message_keys = []

    new_language_lines = []
    for locale_tag in locale_tags:
        if locale_tag in props:
            continue
        label_input = prompt_value(f"Display name for {locale_tag}:", locale_tag)
        label = escape_properties_value(label_input)
        new_language_lines.append(f"{locale_tag} = {label}")
        props[locale_tag] = label
        added_locales.append(locale_tag)

    if new_language_lines:
        insert_at = update_marker if update_marker is not None else len(lines)
        while insert_at > 0 and lines[insert_at - 1].strip() == "":
            insert_at -= 1
        needs_blank = (
            update_marker is not None
            and insert_at > 0
            and lines[insert_at - 1].strip() != ""
        )
        if needs_blank:
            new_language_lines.append("")
        lines[insert_at:insert_at] = new_language_lines

    new_message_lines = []
    for locale_tag in locale_tags:
        key = resolve_confirmation_key(locale_tag, props)
        if key in props:
            continue
        message_input = prompt_value(
            f"Confirmation message for {locale_tag}:", english_message
        )
        message_value = escape_properties_value(message_input)
        new_message_lines.append(f"{key} = {message_value}")
        props[key] = message_value
        added_message_keys.append(key)

    if new_message_lines:
        last_msg_idx = None
        for idx, line in enumerate(lines):
            if line.strip().startswith("languageConfirmation.message."):
                last_msg_idx = idx
        insert_at = (last_msg_idx + 1) if last_msg_idx is not None else len(lines)
        lines[insert_at:insert_at] = new_message_lines

    if new_language_lines or new_message_lines:
        write_lines(SET_OF_LANGUAGES_PATH, lines, newline, has_trailing_newline)

    confirmation_key_map = {
        locale_tag: resolve_confirmation_key(locale_tag, props)
        for locale_tag in locale_tags
    }
    return added_locales, added_message_keys, confirmation_key_map


def update_banner(locale_tags, confirmation_key_map):
    lines, newline, has_trailing_newline = read_lines(BANNER_PATH)

    chooser_idx = None
    for idx, line in enumerate(lines):
        if 'id="language-chooser"' in line:
            chooser_idx = idx
            break
    if chooser_idx is None:
        print("language-chooser block not found in banner.jsp", file=sys.stderr)
        return [], []

    select_start = None
    for idx in range(chooser_idx, len(lines)):
        if "<select" in lines[idx]:
            select_start = idx
            break
    if select_start is None:
        print("select element not found in banner.jsp", file=sys.stderr)
        return [], []

    select_end = None
    for idx in range(select_start, len(lines)):
        if "</select>" in lines[idx]:
            select_end = idx
            break
    if select_end is None:
        print("select end not found in banner.jsp", file=sys.stderr)
        return [], []

    option_re = re.compile(r'<option value="([^"]+)"')
    existing_options = set()
    option_indent = None
    option_inner_indent = None
    for idx in range(select_start, select_end + 1):
        match = option_re.search(lines[idx])
        if match:
            existing_options.add(match.group(1))
            if option_indent is None:
                option_indent = re.match(r"\s*", lines[idx]).group(0)
                if idx + 1 <= select_end:
                    option_inner_indent = re.match(r"\s*", lines[idx + 1]).group(0)
    if option_indent is None:
        option_indent = re.match(r"\s*", lines[select_start]).group(0) + "\t"
    if option_inner_indent is None:
        option_inner_indent = option_indent + "\t"

    new_options = []
    added_options = []
    for locale_tag in locale_tags:
        if locale_tag in existing_options:
            continue
        added_options.append(locale_tag)
        new_options.extend(
            [
                f'{option_indent}<option value="{locale_tag}">',
                f'{option_inner_indent}<bean:message bundle="setOfLanguagesBundle" key="{locale_tag}" />',
                f"{option_indent}</option>",
            ]
        )
    if new_options:
        lines[select_end:select_end] = new_options

    span_start = None
    for idx in range(select_end, len(lines)):
        if "<span" in lines[idx] and 'id="updateMessage"' in lines[idx]:
            span_start = idx
            break
    if span_start is None:
        print("updateMessage span not found in banner.jsp", file=sys.stderr)
        return added_options, []

    span_end = None
    for idx in range(span_start, len(lines)):
        if "</span>" in lines[idx]:
            span_end = idx
            break
    if span_end is None:
        print("updateMessage span end not found in banner.jsp", file=sys.stderr)
        return added_options, []

    data_re = re.compile(r"data-message-([^=]+)=")
    existing_data = set()
    data_indent = None
    for idx in range(span_start, span_end + 1):
        match = data_re.search(lines[idx])
        if match:
            existing_data.add(match.group(1))
            if data_indent is None:
                data_indent = re.match(r"\s*", lines[idx]).group(0)
    if data_indent is None:
        data_indent = re.match(r"\s*", lines[span_start]).group(0) + "\t"

    new_data_lines = []
    added_data = []
    for locale_tag in locale_tags:
        if locale_tag in existing_data:
            continue
        message_key = confirmation_key_map.get(
            locale_tag, resolve_confirmation_key(locale_tag, {})
        )
        new_data_lines.append(
            f'{data_indent}data-message-{locale_tag}=\'<bean:message bundle="setOfLanguagesBundle" key="{message_key}"/>\''
        )
        added_data.append(locale_tag)

    if new_data_lines:
        lines[span_end:span_end] = new_data_lines

    if new_options or new_data_lines:
        write_lines(BANNER_PATH, lines, newline, has_trailing_newline)

    return added_options, added_data


def main():
    locale_tags = discover_locale_tags()
    if not locale_tags:
        print("No locales found to add.")
        return 0

    added_locales, added_message_keys, confirmation_key_map = update_set_of_languages(
        locale_tags
    )
    added_options, added_data = update_banner(locale_tags, confirmation_key_map)

    if not (added_locales or added_message_keys or added_options or added_data):
        print("No changes needed.")
        return 0

    if added_locales:
        print(f"Added language entries: {', '.join(added_locales)}")
    if added_message_keys:
        print(f"Added confirmation messages: {', '.join(added_message_keys)}")
    if added_options:
        print(f"Added banner options: {', '.join(added_options)}")
    if added_data:
        print(f"Added banner data messages: {', '.join(added_data)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

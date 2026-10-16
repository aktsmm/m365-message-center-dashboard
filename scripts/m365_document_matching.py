"""Local-only query minimization and conservative, evidence-based article matching."""

import re
from urllib.parse import urlsplit

# Only these public product/feature words can leave the process as a generated query.
# Unrecognized title/body words, names, identifiers, URLs and numbers never leave it.
PUBLIC_WORDS = set("""
microsoft azure entra identity authentication authenticator passkey passkeys fido2
password passwordless multifactor mfa sspr sms voice sign signin registration campaign
conditional access protection policy policies governance guest guests external b2b
federated token validation app application applications instance lock properties
agent agents agentidentity createasmanager permission permissions manager roles role
copilot chat studio cowork notebook notebooks memory personalization session persistence
read aloud audio overview voice notes prompts scheduled organization organizational
message messages consumption credits metered billing cost costs usage reports report
activity active users analytics insights registry duplicate entries version history
admin center portal all employee self service executive assistant people connectors
connected experiences web grounding domain exclusion search library entity inserts
input branded footer customization code previews license request custom flow mobile
windows mac macos ios android desktop edge browser browsing tab page workspaces
autoupdate mau cdn endpoint endpoints office ltsc support lifecycle update updates
release targeted preferences group groups calendar calendars shared mapi rest outlook
excel word powerpoint brand kit branding brands public optional setup install deployment
esignature recipient recipients signing signatures sharepoint onedrive teams meeting
meetings organizer transcription ai viva connections assignments courses adaptive card
extensions ace purview sensitivity labels content encryption security defender guard
css layout positioning company first factor system preferred credential hello business
platform sso api graph readbasic approleassignments license details data granular attribute
attributes catalog sites taskbar pinning subprocessor openai profile cards visibility
skills mapping upload files folder sharing recovery window backup workloads exchange
retention edcn ecdn captcha partner tier restore export network domains roadmap power
planner tasks manifest mv2 mv3 unload internet explorer mode companions companion
rollback monthly enterprise channel citrix mvpn declarative observability platforms
gallery onboarding oidc audit logs log connect connections email sender address
improved optimized enhanced manage management controls control enable create remove
retirement migration preview general availability default basic secure secureboot
connectedapps accessibility compliance metadata integration performance searchquery
jailbreak root detection image insert ribbon design first endpoint policylink
reading organizer rate limit quotas trial education upgrade captcha lockout custom
intune iphone ipad authenticationstrengths synchronization hybrid configuration
""".split())

STOP_WORDS = set("""
microsoft azure updated update updates new introducing introduce introduction upcoming
changes change changing enhanced enhancement improved improvements optimized
optimizations experience experiences manage management controls control available
availability general preview public private release rollout default support supported
retirement retiring retire retired deprecation deprecated moves moving ends end
starting using use users user allow allows enabling enable create creating all
admin center organization organizational app apps application applications
access policy policies settings setting information content data details feature features
a an the of for with in on at to and or as by from into through across after before
now soon will is are be been being its this that your you can may required review
who how what which when why than more most only not no up out about
enabled automatically automatic expands expanded expands enhancements simplify action
""".split())

PRODUCTS = (
    ("entra", ("entra", "authenticator", "fido2"), ("entra/", "identity/")),
    ("teams", ("teams",), ("microsoftteams/",)),
    ("sharepoint", ("sharepoint", "brand center"), ("sharepoint/", "microsoft-365/documentprocessing/")),
    ("purview", ("purview", "sensitivity label"), ("purview/",)),
    ("edge", ("edge",), ("deployedge/", "microsoft-edge/", "copilot/edge")),
    ("backup", ("microsoft 365 backup",), ("microsoft-365/backup/",)),
    ("copilot-studio", ("copilot studio",), ("microsoft-copilot-studio/",)),
    ("agent365", ("agent 365",), ("microsoft-agent-365/", "microsoft-365/admin/")),
    ("exchange", ("exchange", "recipient rate"), ("exchange/", "office365/servicedescriptions/exchange",)),
    ("graph", ("microsoft graph",), ("graph/",)),
    ("copilot", ("copilot",), ("copilot/", "microsoft-365/copilot/", "microsoft-365/admin/activity-reports/")),
    ("office", ("office", "microsoft 365 apps", "autoupdate"), ("microsoft-365-apps/", "lifecycle/", "officeupdates/")),
)
PLATFORMS = {"windows", "mac", "macos", "ios", "android", "web"}
SYNONYMS = {
    "passkeys": "passkey", "notebooks": "notebook", "agents": "agent",
    "reports": "report", "calendars": "calendar", "messages": "message",
    "labels": "label", "skills": "skill", "prompts": "prompt", "recipients": "recipient",
    "applications": "application", "policies": "policy", "permissions": "permission",
    "properties": "property", "groups": "group", "logs": "log", "costs": "cost",
    "sign-in": "signin", "sign-ins": "signin", "macos": "mac",
    "identities": "identity", "tokens": "token", "restrictions": "restriction",
    "assignments": "assignment", "meetings": "meeting", "features": "feature",
    "controls": "control", "signatures": "signature", "queries": "query",
}


def words(value):
    # Prevent fragments of private addresses/URLs/identifiers from becoming queries.
    value = re.sub(r"https?://\S+|\S+@\S+|\b[0-9a-f]{8}-[0-9a-f-]{27,}\b", " ", value, flags=re.I)
    return re.findall(r"[a-z][a-z0-9]*", value.lower())


def tokens(value):
    return {SYNONYMS.get(word, word) for word in words(value)}


def public_query(message):
    """No raw title or body is ever transmitted, even for a previously unseen MC ID."""
    title = message.get("title", "")
    safe = list(dict.fromkeys(word for word in words(title) if word in PUBLIC_WORDS
                             and word not in {"updated", "updates", "changes", "improved", "enhanced"}))
    if len(safe) < 2:
        safe = list(dict.fromkeys(word for service in message.get("services", [])
                                 for word in words(service) if word in PUBLIC_WORDS))[:6]
    # Prefix and words are constant/public; an empty feature still gets a bounded search.
    query = " ".join(["Microsoft"] + [word for word in safe if word != "microsoft"][:22])
    safe_query(query)
    return query


def safe_query(value):
    found = words(value)
    if not found or any(word not in PUBLIC_WORDS for word in found) or len(found) > 30:
        raise ValueError("Search query contains words outside the public product/feature vocabulary")
    return " ".join(found)


def product(message):
    text = message.get("title", "").lower()
    for name, aliases, paths in PRODUCTS:
        if any(re.search(r"\b" + re.escape(alias) + r"\b", text) for alias in aliases):
            return name, aliases, paths
    return "microsoft365", ("microsoft 365",), ("microsoft-365/", "microsoft-365-apps/", "graph/")


def passages(body):
    """Match within an article section/window, not unrelated terms across a release log."""
    result = []
    for section in re.split(r"(?m)(?=^#{1,6}\s)", body):
        for start in range(0, len(section), 1400):
            text = section[start:start + 2200]
            if text.strip():
                result.append(text)
    return result


def relevance(message, url, body):
    family, aliases, paths = product(message)
    path = re.sub(r"^/[a-z]{2}-[a-z]{2}/", "", urlsplit(url).path).lstrip("/")
    title = message.get("title", "")
    title_tokens = tokens(title)
    product_tokens = tokens(" ".join(aliases))
    features = title_tokens - tokens(" ".join(STOP_WORDS)) - product_tokens - PLATFORMS - {"365"}
    if "who can create" in title.lower():
        features.update({"create", "permission"})
    # Matching must use the real feature, not just product/platform names.
    if not features:
        return None
    platform = title_tokens & tokens(" ".join(PLATFORMS))
    scope = any(path.startswith(prefix) for prefix in paths)
    best = None
    for passage in passages(body):
        lower = passage.lower()
        present = tokens(passage)
        family_match = scope or any(re.search(r"\b" + re.escape(alias) + r"\b", lower) for alias in aliases)
        matched = features & present
        coverage = len(matched) / len(features)
        # Unknown feature words remain local and must also match the article.
        if not family_match or len(matched) < min(2, len(features)) or coverage < 0.7:
            continue
        if platform and not platform <= present:
            continue
        # Distinguish workforce identities from the similarly named customer platform.
        if family == "entra" and "/customers/" in "/" + path and "customer" not in title.lower():
            continue
        # Generic headings/landing pages do not establish feature relevance.
        article_title = body.splitlines()[0].lower() if body else ""
        heading_match = len(features & tokens(article_title)) >= min(2, len(features))
        if re.search(r"(?:^|[-/])overview(?:$|[-/])", path) and not heading_match:
            continue
        if not heading_match and coverage < 0.9:
            continue
        score = round(coverage + (0.2 if heading_match else 0), 3)
        evidence = {
            "product": family, "matchedTerms": sorted(matched),
            "requiredFeatureTerms": sorted(features), "coverage": round(coverage, 3),
            "platforms": sorted(platform), "score": score,
            # Only public article text, never notification text.
            "articleExcerpt": passage[:2200],
        }
        if best is None or score > best["score"]:
            best = evidence
    return best

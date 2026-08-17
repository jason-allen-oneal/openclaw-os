#!/usr/bin/env python3
"""Delete only branches whose current tip is known to be safely merged."""

from __future__ import annotations

import json
import os
import sys
from dataclasses import dataclass
from typing import Any, Iterable
from urllib.error import HTTPError
from urllib.parse import quote, urlencode
from urllib.request import Request, urlopen

TRANSIENT_PREFIXES = (
    "build/",
    "chore/",
    "ci/",
    "docs/",
    "feat/",
    "fix/",
    "perf/",
    "refactor/",
    "test/",
)


@dataclass(frozen=True)
class BranchDecision:
    delete: bool
    reason: str


def evaluate_branch(
    *,
    branch: str,
    branch_sha: str,
    default_branch: str,
    protected: bool,
    has_open_pull_request: bool,
    merged_pull_request_head_shas: Iterable[str],
    ahead_by: int | None,
) -> BranchDecision:
    """Return a fail-closed deletion decision for one branch."""

    if not branch or branch == default_branch:
        return BranchDecision(False, "default branch")
    if protected:
        return BranchDecision(False, "protected")
    if has_open_pull_request:
        return BranchDecision(False, "still used by an open pull request")
    if not branch_sha:
        return BranchDecision(False, "missing branch tip")

    merged_head_shas = {
        value for value in merged_pull_request_head_shas if isinstance(value, str) and value
    }
    is_transient = branch.startswith(TRANSIENT_PREFIXES)
    if not merged_head_shas and not is_transient:
        return BranchDecision(False, "not a merged PR branch or transient branch")

    if ahead_by == 0:
        return BranchDecision(True, f"fully contained in {default_branch}")

    if branch_sha in merged_head_shas:
        return BranchDecision(True, "current tip exactly matches a confirmed merged PR head")

    return BranchDecision(False, f"contains commits not in {default_branch} or advanced after merge")


class GitHubApi:
    def __init__(self, *, token: str, repository: str, api_url: str) -> None:
        self.repository = repository
        self.api_url = api_url.rstrip("/")
        self.headers = {
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "User-Agent": "openclaw-os-branch-cleanup",
            "X-GitHub-Api-Version": "2022-11-28",
        }

    def request_json(
        self,
        path: str,
        *,
        method: str = "GET",
        allow_not_found: bool = False,
    ) -> Any:
        request = Request(f"{self.api_url}{path}", headers=self.headers, method=method)
        try:
            with urlopen(request, timeout=30) as response:
                body = response.read()
        except HTTPError as error:
            detail = error.read().decode("utf-8", errors="replace")
            if allow_not_found and error.code == 404:
                return None
            raise RuntimeError(
                f"GitHub API {method} {path} failed with {error.code}: {detail}"
            ) from error
        if not body:
            return None
        return json.loads(body)

    def paginated_list(self, path: str, query: dict[str, Any]) -> list[dict[str, Any]]:
        entries: list[dict[str, Any]] = []
        page = 1
        while True:
            page_query = {**query, "per_page": 100, "page": page}
            batch = self.request_json(f"{path}?{urlencode(page_query)}")
            if not isinstance(batch, list):
                raise RuntimeError(f"GitHub returned an invalid list for {path}")
            entries.extend(entry for entry in batch if isinstance(entry, dict))
            if len(batch) < 100:
                return entries
            page += 1

    def list_branches(self) -> list[dict[str, Any]]:
        return self.paginated_list(f"/repos/{self.repository}/branches", {})

    def pull_requests(
        self,
        *,
        owner: str,
        branch: str,
        state: str,
        base: str | None = None,
    ) -> list[dict[str, Any]]:
        query: dict[str, Any] = {
            "state": state,
            "head": f"{owner}:{branch}",
        }
        if base:
            query["base"] = base
        return self.paginated_list(f"/repos/{self.repository}/pulls", query)

    def compare(self, *, base: str, head: str) -> dict[str, Any] | None:
        comparison_ref = f"{quote(base, safe='')}...{quote(head, safe='')}"
        comparison = self.request_json(
            f"/repos/{self.repository}/compare/{comparison_ref}",
            allow_not_found=True,
        )
        return comparison if isinstance(comparison, dict) else None

    def delete_branch(self, branch: str) -> None:
        encoded_branch = quote(branch, safe="")
        self.request_json(
            f"/repos/{self.repository}/git/refs/heads/{encoded_branch}",
            method="DELETE",
            allow_not_found=True,
        )


def cleanup_branches(*, api: GitHubApi, owner: str, default_branch: str) -> tuple[list[str], list[str]]:
    deleted: list[str] = []
    skipped: list[str] = []

    for entry in api.list_branches():
        branch = entry.get("name")
        if not isinstance(branch, str) or not branch or branch == default_branch:
            continue

        commit = entry.get("commit")
        branch_sha = commit.get("sha") if isinstance(commit, dict) else ""
        if not isinstance(branch_sha, str):
            branch_sha = ""

        protected = entry.get("protected") is True
        open_prs = api.pull_requests(owner=owner, branch=branch, state="open")
        merged_prs = [
            pr
            for pr in api.pull_requests(
                owner=owner,
                branch=branch,
                state="closed",
                base=default_branch,
            )
            if pr.get("merged_at")
        ]
        merged_head_shas = [
            head.get("sha")
            for pr in merged_prs
            if isinstance((head := pr.get("head")), dict)
            and isinstance(head.get("sha"), str)
        ]

        comparison = api.compare(base=default_branch, head=branch)
        ahead_by = comparison.get("ahead_by") if comparison else None
        if not isinstance(ahead_by, int):
            ahead_by = None

        decision = evaluate_branch(
            branch=branch,
            branch_sha=branch_sha,
            default_branch=default_branch,
            protected=protected,
            has_open_pull_request=bool(open_prs),
            merged_pull_request_head_shas=merged_head_shas,
            ahead_by=ahead_by,
        )
        if not decision.delete:
            skipped.append(f"{branch}: {decision.reason}")
            continue

        api.delete_branch(branch)
        deleted.append(branch)
        print(f"Deleted merged branch: {branch} ({decision.reason})")

    return deleted, skipped


def main() -> int:
    token = os.environ.get("GITHUB_TOKEN", "")
    repository = os.environ.get("GITHUB_REPOSITORY", "")
    api_url = os.environ.get("GITHUB_API_URL", "https://api.github.com")
    default_branch = os.environ.get("DEFAULT_BRANCH", "main")

    if not token or not repository or "/" not in repository:
        raise SystemExit("GitHub workflow context is incomplete")
    if not default_branch:
        raise SystemExit("Default branch is missing")

    owner, _ = repository.split("/", 1)
    api = GitHubApi(token=token, repository=repository, api_url=api_url)
    deleted, skipped = cleanup_branches(
        api=api,
        owner=owner,
        default_branch=default_branch,
    )

    if skipped:
        print("Branches retained:")
        for reason in skipped:
            print(f"  {reason}")
    print(f"Deleted {len(deleted)} merged branch(es).")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:  # noqa: BLE001 - fail the workflow with context
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)

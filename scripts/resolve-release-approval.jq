[
  .[]
  | select(((.state // "") | ascii_downcase) == "approved")
  | . as $review
  | .environments[]?
  | select(.name == "alpha-release")
  | select(($review.user.login | type) == "string")
  | select(($review.user.login | length) > 0)
  | {
      role: "release-owner",
      login: $review.user.login,
      observedAt: $observed_at,
      timestampSource: "protected-job-start",
      method: "protected-environment",
      environment: .name,
      runUrl: $run_url,
      jobId: $job_id,
      runAttempt: $run_attempt
    }
]
| sort_by(.login)
| last

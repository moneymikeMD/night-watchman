---
date: 2026-10-01
slug: public-repos-need-no-approving-review-green-required-checks-are-the-gate
title: "Public repos need no approving review; green required checks are the gate"
---

# Public repos need no approving review; green required checks are the gate

## Decision

Owner decided 2026-10-01 that night-watchman, work-order, switchtender and moneymike-plugins rulesets set required_approving_review_count 0 with no code-owner review. A PR, blocked deletion and force-push, admin bypass and required checks stay. no-major is required in all four, so NWM-163 was cancelled.

## Why

Every PR from these sessions is authored by the owner account and GitHub blocks self-approval, so the review rule could never be met and forced an admin merge every time. It replaces the earlier premise that admin bypass is the standing path.

## Cost

unrecorded in memory 98fd5889

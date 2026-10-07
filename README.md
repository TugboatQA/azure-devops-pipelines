# Tugboat Azure DevOps Test

This repository is a reference setup for using Tugboat with a repository hosted in Azure Repos. Tugboat has no Azure DevOps integration, so Azure Pipelines calls the Tugboat API to provide the same pull request automation that Tugboat provides for GitHub, GitLab, and Bitbucket:

- Opening a pull request creates a Tugboat preview.
- Pushing commits to a pull request rebuilds its preview.
- Completing or abandoning a pull request deletes its preview.
- A nightly schedule refreshes the base previews and rebuilds their child previews.
- Each pull request gets three status checks: `Tugboat`, `Tugboat - Visual Diffs`, and `Tugboat - Lighthouse Reports`.

The site itself is a single static page (`index.html`) served by Apache, as configured in `.tugboat/config.yml`.

## How it works

| File | Runs when | What it does |
| --- | --- | --- |
| `.azure-pipelines/tugboat-pr.yml` | An Azure DevOps service hook reports that a pull request was created, received commits, or changed status | Reads the pull request from the Azure DevOps API. If it is active, creates or rebuilds its preview, waits for the build, Visual Diffs, and Lighthouse reports, and posts the status checks. If it is completed or abandoned, deletes its preview. |
| `.azure-pipelines/tugboat-nightly.yml` | Daily at 00:08 UTC | Deletes previews whose pull request is closed, then refreshes each unlocked base preview and rebuilds its child previews. |
| `.azure-pipelines/scripts/` | Called by the pipelines | Bash scripts that use `curl` and `jq` to call the Tugboat and Azure DevOps APIs. |

The pipelines name each preview they create `Azure PR #<id>: <title>` and find it again by that name. Previews with other names, such as previews that people create in the Tugboat dashboard, are never changed or deleted.

## Setup

### 1. Azure DevOps

1. Create an organization and a project at https://dev.azure.com.
2. Push this repository to a new repository in **Repos**. Use `main` as the default branch.
3. Enable pipeline runs, using one of:
   - **Organization settings > Billing**: link an Azure subscription. This enables the free Microsoft-hosted tier.
   - **Project settings > Agent pools**: register a self-hosted agent, then change `pool:` in each pipeline file to that pool.

### 2. Tugboat

1. In Tugboat, create a project and add a repository using the **Git** provider with the SSH clone URL from **Repos > Clone > SSH**.
2. Add the Tugboat repository's public SSH key in Azure DevOps under **User settings > SSH public keys**, as a user with read access to the repository.
3. Build a preview of `main` and set it as a base preview.
4. Create a Tugboat access token for the pipelines.

### 3. Pipeline variables

1. Go to **Pipelines > Library** and create a variable group named `tugboat`.
2. Add `TUGBOAT_REPO` with the Tugboat repository ID.
3. Add `TUGBOAT_API_TOKEN` with the Tugboat access token. Select the lock icon to make it secret.

For an on-premise Tugboat installation, also add:

- `TUGBOAT_API`: `https://api.<your Tugboat domain>/v3`
- `TUGBOAT_DASHBOARD`: `https://dashboard.<your Tugboat domain>`

### 4. Permission to post status checks

1. Go to **Project settings > Repositories**, select the repository, and open **Security**.
2. Select **\<project name\> Build Service (\<organization name\>)**.
3. Set **Contribute to pull requests** to **Allow**.

### 5. Incoming webhook

1. Go to **Project settings > Service connections > New service connection > Incoming WebHook**.
2. Set both **WebHook Name** and **Service connection name** to `tugboat-pull-request`.
3. Select **Grant access permission to all pipelines** and save.

### 6. Pipelines

For each of `tugboat-pr.yml` and `tugboat-nightly.yml`:

1. Go to **Pipelines > New pipeline > Azure Repos Git**, select the repository, then **Existing Azure Pipelines YAML file**.
2. Select the file, then select **Run**. Name the pipeline after the file.
3. When prompted, allow the pipeline to use the `tugboat` variable group.

The first manual run of `tugboat-pr` fails with "Invalid pull request ID". This is expected; the run registers the webhook.

### 7. Service hooks

Go to **Project settings > Service hooks** and create three **Web Hooks** subscriptions, all for this repository and all with this **URL**:

```
https://dev.azure.com/<organization name>/_apis/public/distributedtask/webhooks/tugboat-pull-request?api-version=6.0-preview
```

| Trigger on this type of event | Change |
| --- | --- |
| Pull request created | (none) |
| Pull request updated | Source branch updated |
| Pull request updated | Status changed |

### 8. Optional: require status checks

1. Go to **Repos > Branches**, open the `main` branch menu, and select **Branch policies**.
2. Under **Status Checks**, add a required policy for each of:
   - `tugboat/Tugboat`
   - `tugboat/Tugboat - Visual Diffs`
   - `tugboat/Tugboat - Lighthouse Reports`

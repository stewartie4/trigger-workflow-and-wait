#!/bin/sh
set -e
set -o xtrace

usage_docs() {
  echo ""
  echo "You can use this Github Action with:"
  echo "- uses: convictional/trigger-workflow-and-wait"
  echo "  with:"
  echo "    owner: keithconvictional"
  echo "    repo: myrepo"
  echo "    github_token: \${{ secrets.GITHUB_PERSONAL_ACCESS_TOKEN }}"
  echo "    workflow_file_name: main.yaml"
}
GITHUB_API_URL="${API_URL:-https://api.github.com}"
GITHUB_SERVER_URL="${SERVER_URL:-https://github.com}"

validate_args() {
  wait_interval=60 # Waits for 60 seconds
  if [ "${INPUT_WAITING_INTERVAL}" ]
  then
    wait_interval=${INPUT_WAITING_INTERVAL}
  fi

  propagate_failure=true
  if [ -n "${INPUT_PROPAGATE_FAILURE}" ]
  then
    propagate_failure=${INPUT_PROPAGATE_FAILURE}
  fi

  trigger_workflow=true
  if [ -n "${INPUT_TRIGGER_WORKFLOW}" ]
  then
    trigger_workflow=${INPUT_TRIGGER_WORKFLOW}
  fi

  wait_workflow=true
  if [ -n "${INPUT_WAIT_WORKFLOW}" ]
  then
    wait_workflow=${INPUT_WAIT_WORKFLOW}
  fi

  if [ -z "${INPUT_OWNER}" ]
  then
    echo "Error: Owner is a required argument."
    usage_docs
    exit 1
  fi

  if [ -z "${INPUT_REPO}" ]
  then
    echo "Error: Repo is a required argument."
    usage_docs
    exit 1
  fi

  if [ -z "${INPUT_GITHUB_TOKEN}" ]
  then
    echo "Error: Github token is required. You can head over settings and"
    echo "under developer, you can create a personal access tokens. The"
    echo "token requires repo access."
    usage_docs
    exit 1
  fi

  if [ -z "${INPUT_WORKFLOW_FILE_NAME}" ]
  then
    echo "Error: Workflow File Name is required"
    usage_docs
    exit 1
  fi

  inputs=$(echo '{}' | jq)
  if [ "${INPUT_INPUTS}" ]
  then
    inputs=$(echo "${INPUT_INPUTS}" | jq)
  fi

  ref="main"
  if [ "$INPUT_REF" ]
  then
    ref="${INPUT_REF}"
  fi
}

trigger_workflow() {
  curl --fail -X POST "${GITHUB_API_URL}/repos/${INPUT_OWNER}/${INPUT_REPO}/actions/workflows/${INPUT_WORKFLOW_FILE_NAME}/dispatches" \
    -H "Accept: application/vnd.github.v3+json" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${INPUT_GITHUB_TOKEN}" \
    --data "{\"ref\":\"${ref}\",\"inputs\":${inputs}}" \ || { echo "Failed to execute workflow. Check target branch exists in [${INPUT_OWNER}/${INPUT_REPO}]" && exit 1; }
}

wait_for_workflow_to_finish() {
  # Find the id of the last run using filters to identify the workflow triggered by this action
  echo "Getting the ID of the workflow..."
  query="event=workflow_dispatch&status=queued"
  if [ "$INPUT_GITHUB_USER" ]
  then
    query="${query}&actor=${INPUT_GITHUB_USER}"
  fi
  last_workflow="null"
  counter=0;
  while [[ "$last_workflow" == "null" && $counter -lt 30 ]]
  do
    last_workflow_response=$(curl -s -X GET "${GITHUB_API_URL}/repos/${INPUT_OWNER}/${INPUT_REPO}/actions/workflows/${INPUT_WORKFLOW_FILE_NAME}/runs?${query}" \
      -H 'Accept: application/vnd.github.antiope-preview+json' \
      -H "Authorization: Bearer ${INPUT_GITHUB_TOKEN}")
     
    last_workflow=$(echo $last_workflow_response | jq '[.workflow_runs[]] | first')
    ((counter=counter+1))
    sleep 1
  done
  
  if [ "$last_workflow" == "null" ]; then
      echo "Workflow was not triggered after 30s. Failing."
      exit 1
  fi
  
  last_workflow_id=$(echo "${last_workflow}" | jq '.id')
  last_workflow_url="${GITHUB_SERVER_URL}/${INPUT_OWNER}/${INPUT_REPO}/actions/runs/${last_workflow_id}"
  echo "The workflow id is [${last_workflow_id}]."
  echo "The workflow logs can be found at ${last_workflow_url}"
  echo "::set-output name=workflow_id::${last_workflow_id}"
  echo "::set-output name=workflow_url::${last_workflow_url}"
  echo ""
  conclusion=$(echo "${last_workflow}" | jq '.conclusion')
  status=$(echo "${last_workflow}" | jq '.status')

  while [[ "${conclusion}" == "null" && "${status}" != "\"completed\"" ]]
  do
    echo "Sleeping for \"${wait_interval}\" seconds..."
    sleep "${wait_interval}"
    workflow=$(curl -s -X GET "${GITHUB_API_URL}/repos/${INPUT_OWNER}/${INPUT_REPO}/actions/workflows/${INPUT_WORKFLOW_FILE_NAME}/runs" \
      -H 'Accept: application/vnd.github.antiope-preview+json' \
      -H "Authorization: Bearer ${INPUT_GITHUB_TOKEN}" | jq '.workflow_runs[] | select(.id == '${last_workflow_id}')')
    conclusion=$(echo "${workflow}" | jq '.conclusion')
    status=$(echo "${workflow}" | jq '.status')
    echo "Workflow conclusion is [${conclusion}]"
    echo "Workflow status is [${status}]"
    echo "The workflow logs can be found at ${last_workflow_url}"
    echo
  done

   echo "The workflow logs can be found at ${last_workflow_url}"
  if [[ "${conclusion}" == "\"success\"" && "${status}" == "\"completed\"" ]]
  then
    echo "Workflow exited successfully"
  else
    # Alternative "failure"
    echo "Workflow did not exit successfully, exited with a status of [${conclusion}]."
    if [ "${propagate_failure}" = true ]
    then
      echo "Propagating failure to upstream job"
      exit 1
    fi
  fi
}

main() {
  validate_args

  if [ "${trigger_workflow}" = true ]
  then
    trigger_workflow
  else
    echo "Skipping triggering the workflow."
  fi

  if [ "${wait_workflow}" = true ]
  then
    wait_for_workflow_to_finish
  else
    echo "Skipping waiting for workflow."
  fi
}

main

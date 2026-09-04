# Troubleshooting Workspace

## User

The user is a Power BI support engineer tasked with troubleshooting complex issues with the Microsoft Power BI service. They have access to back-end Power BI service logs via Kusto, a robust internal Wiki that acts as an internal knowledge base, and the official Microsoft Learn docs. 

## Purpose

## Tools

Available through PATH:

    - jq.exe (for analyzing .HAR files)
    - lnav.exe (for analyzing text files)
    - duckdb (for CSV and temporary analytic data)
    - 

## Context Limits

You are an AI agent with limited context. The user often works with massive quantities of text files. Analyzing them requires a prudent approach to save your context from becoming overwhelmed due to basic context limits.

Consider the following strategies:
- Act as an architect and planner agent that coordinates subagents to perform any heavy lifting for you.
- Author or commission PowerShell and other types of scripts for the purpose of aggregating data from log files you're likely to see again.
- 

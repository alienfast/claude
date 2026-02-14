# Prompts that were useful and may be again

## update tooling

```text
/do use the ../js project as inspiration, and be sure the project has tooling implemented similarly:  
 - Create a git branch called tooling
 - Remove eslint and prettier from this project, replace with biome and markdownlint
 - Update the .vscode settings changes  
 - Remove the typescript project references and implement the similar check-types.  
 - Add the check-circular, and change the script names here to be consistent with the ones from the ../js project.  
 - Update all script names with ':" in them, e.g. clean:pnpm -> clean-pnpm
 - Migrate any uses of tsup to tsdown
 - Migrate any uses of vite for library builds (as indicated by the build script, or evidence of vite.config.lib.ts) to tsdown
 - Verify in the end after all is done with a call to pnpm check, which should be like the one in ../js.
 - Once complete, update the CLAUDE.md with any changes.
 - Create a git commit
 - Push a PR to github
```

## update our own instructions

```text
/do our ~/.claude instructions grow over time, and sometimes there are redundancies or inefficiencies.  In addition, as claude models and tools like skills, agents, and commands grow in capability, and we want to be sure we are providing the optimal instruction set to achieve our goals.  We don't want to be overly prescriptive.

Research the best practices for using claude code as of this month, December 2025.  Do a comprehensive review of our files.  Ask any questions needed.  Suggest any changes you think might be useful.

Some repeated problems I am seeing:
Specifically, I am seeing a pattern of suggested workarounds as an easy way out.  I have a strong preference to avoid workarounds.  I am not sure why it is a common suggestion, but I want to make some changes in this regard so we move the codebase forward.  Perhaps I am not providing clarity with the goal?  If so, I want future sessions to stop and ask me for more guidance.  Perhaps you are stuck and spending a lot of time researching but the research is not fruitful?  Perhaps I could give some direction if you ask me?
```

## big project+global update instructions

```
/do our CLAUDE.md and ./.claude files grow over time, and sometimes there are redundancies or inefficiencies.  In addition, as claude models and tools like skills, agents, and commands grow in capability, and we want to be sure we are providing the optimal instruction set to achieve our goals.  We don't want to be overly prescriptive.

Research the best practices for using claude code as of this month, December 2025.  Do a comprehensive review of our files.  Ask any questions needed.  Suggest any changes you think might be useful.  We should preserve context where possible, and use progressive disclosure in skills. Evaluate not just the ./.claude and CLAUDE.md files in this, our primary project, but also analyze our global ~/.claude/* files for duplication, redundancies, inefficiencies, inaccuracies.  Find ways to improvem them.
```

---
name: Do we need Vim at this point?
created: 2026-08-13
---
I am a pretty heavy Neovim user, and recently at my job I did a 1-hour talk
spreading the gospel of Vim (it was like 15 people or something, so the meeting
was not that big). 

After the meeting, my coworker asked me some questions, one of which was "Now
that people almost don't write code, how do you work with Vim? Is there a big
need for a text editor? Right now I would rather have multiple chats and a good
review tool." And while I dread this new world where I have given away all the
fun stuff to an LLM and slowly watch my skills and myself rot away, this is a
good question to ask, since (unfortunately) LLMs will probably stay in this
profession in some shape.

It is a good enough question to force me to make a medium-sized response and
create a blog where I can house said response (I had been ruminating on
creating a blog for 2 months, so I should thank the person who asked the
question for finally giving me a good reason to do it).

There are two "Vims" we can talk about here: "Vim" as a text editor, and "Vim"
as a broader ecosystem. By "Vim", I mean Neovim, since that's what I use, and
Neovim has a far better ecosystem than Vim just by virtue of community size.

## Do We Need Vim, The Text Editor?

Vim is a powerful tool to make edits to text and to do them en masse. LLMs
are also pretty good at that. So, Vim lost here, right? Not quite. At least in
my opinion, a great text editor has to be a great text viewer. Which Vim is.
Right now, most people still read and review code, which means that Vim is
still a great tool with all of the stuff like LSP support which lets a user
explore the code and its relationship to the rest of the codebase. 

And even if we go the way of "spec-driven development", rendering the code just
as a low-level abstraction, a spec is still text! There are a lot of people who
write books, PhD theses, blogs (I am doing that right now, this is so meta),
and documentation using Vim and are super happy. The job hasn't really changed
at the most basic level: I think very hard and move letters around. And Vim is
still better at the "move letters around" part of the job than other tools.

## Do We Need Vim, The Ecosystem?

Neovim has a great ecosystem of plugins which allow you to:
- Fuzzy search and navigate any type of thing you want via
[pickers](https://github.com/folke/snacks.nvim/blob/main/docs/picker.md).
- Manage [git](https://github.com/neogitorg/neogit).
- Manage and edit the filesystem like a regular
[buffer](https://github.com/stevearc/oil.nvim).
- Work with [RSS](https://github.com/neo451/feed.nvim)
- Do some other crazy stuff I haven't seen. Really, the sky is the limit.
 
These plugins allow people to use the power of Vim by translating different
mediums into text, which it can work with very well already. 

There are [good](https://github.com/pwntester/octo.nvim) review tools already,
and some interesting agent
[management](https://github.com/carlos-algms/agentic.nvim) tools emerging. Some 
people are not fans of putting every single possible thing in their text editor
and making it their shell. Or their operating system. Or their Emacs. I do have
some thoughts about that as well, but that is not the point of the post. The
main point is that LLMs are mostly bound by text, and since Vim works well with
text, it is natural that we will find a way to work with LLMs in a convenient
way in the editor.

## Reemergence of Ex

This is just a fun thought.

The current way LLMs get access to the outside world is through tool calling.
It's basically JSON or XML which a harness parses and executes. There are a lot
of different possible tools, but the bare minimum is to let an agent read,
write, edit files, and use Bash.

Do you know what else does that? Ex (or command-line mode in Vim). And it does
so much more, also in a coherent way where any command (or "tool") can operate
on a specific range of text with the same exact syntax. Maybe in the future, we
will get LLMs to spit Ex commands, and then they will get their own vi.

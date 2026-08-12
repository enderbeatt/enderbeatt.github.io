---
name: Do we need Vim at this point?
created: 2026-08-12
---
I am a pretty heavy Neovim user, and recently at my job I did a 1h talk
spreading the gospel of vim (it was like 15 people or something, so the meeting
was not that big). 

After the meeting my coworker asked me some questions, one of which was "Now
that people almost don't write code, how do you work with vim? is there a big
need in a text editor? right now i would rather have multiple chats and a good
review tool". And while I dread this new world where I have given away all the
fun stuff to an LLM and slowly watch my skills and myself rot away, this is a
good question to ask, since (unfortunately) LLMs will probably stay in this
profession in some shape.

It is a good enough question to force me to make medium-sized response and
make a blog for it (i was ruminating creating a blog for 2 months, so I should
thank the person asking for finally having a good reason to do it).

There are two "vims" we can talk about here: "vim" as a text editor, and "vim"
as a broader ecosystem. By "vim", I mean neovim, since that's what I use, and
neovim has a far better ecosysten than vim just by the virtue of community
size.

## Do we need vim the text editor

Vim is a powerful tool to do edits to the text and to do them at mass. LLMs are
also pretty good at that. So, vim lost here, right? Not quite. At least in my
opinion, a great text editor has to be a great text viewer. Which Vim is. Right 
now most people still read and review code, which means that Vim is still a
great tool with all of the lsp support and stuff which lets a user explore the
code and its relationship to the rest of the codebase. 

And even if we go the way of "spec driven development", rendering the code just
as a low-level abstraction, spec is still a text! There are a lot of people who
write books, PhD theses, blogs (I am doing that right now, this is so meta),
documentation using vim, and are super happy. The job hasn't really changed at 
the most basic level: I think very hard and move letters around. And Vim is still 
better at the "move letters around" part of the job than other tools.

## Do we need vim the ecosystem

Neovim has a great ecosystem of plugins which allow you to:
- Fuzzy search and navigate any type of thing you want via
[pickers](https://github.com/folke/snacks.nvim/blob/main/docs/picker.md).
- Manage [git](https://github.com/neogitorg/neogit).
- Manage and edit filesystem like a regular
[buffer](https://github.com/stevearc/oil.nvim).
- Working with [rss](https://github.com/neo451/feed.nvim)
- Some other crazy stuff I haven't seen. Really, the sky is the limit.
 
These plugins allow to use the power of Vim by translating different mediums
into text, which it can work with very well already. 

There are [good](https://github.com/pwntester/octo.nvim) review tools already,
and some interesting agent
[management](https://github.com/carlos-algms/agentic.nvim) tools emerging. Some 
people are not a fan of putting every single possible thing in their neovim and 
making it like emacs, but I have some thoughts about that as well. The main
point is that LLMs are mostly bound by text, and since Vim works well with
text, it is natural that we will find a way to work with LLMs in a convenient
way in the editor.

## Reemergence of Ex

This is just a fun thought.

The current way LLMs get access to the outer world is through tool calling. It's 
basically json or xml which a harness parses and executes. There are a lot of
different possible tools, but the bare minimum is ability to read, write, edit
files, and using bash.

Do you know what else does that? Ex (or command mode in vim). And it does so
much more, and in a coherent way where any command (or "tool") can operate on a
specific range of text with the smae exact syntax. Maybe in the future, we will
get LLMs to spit Ex commands, and then they will get their own vi.

// Sample writing for the editor mock-up on the home page (src/components/EditorMockup.astro).
// Every note has a few paragraphs and one or two passages Matilde comments on. Matilde's
// comments and her scripted replies only ask or observe; they never rewrite the writing.
// Nothing here is generated: the replies cycle through `replies` in order.

/** A paragraph is plain text with highlighted passages: `{ c: commentId, t: text }`. */
export type Segment = string | { c: string; t: string };

export interface MockComment {
  id: string;
  quote: string;
  text: string;
  /** Scripted answers to whatever the visitor replies, used in turn. */
  replies: string[];
}

export interface MockNote {
  id: string;
  title: string;
  goal: string;
  edited: string;
  paragraphs: Segment[][];
  comments: MockComment[];
  /** The last paragraph is still being written: faded, with a caret. */
  unfinished?: boolean;
}

export interface MockFolder {
  name: string;
  notes: MockNote[];
}

export const DEFAULT_NOTE = "anna";

export const folders: MockFolder[] = [
  {
    name: "Letters",
    notes: [
      {
        id: "anna",
        title: "Letter to Anna",
        goal: "Tell her why I'm moving back.",
        edited: "now",
        unfinished: true,
        paragraphs: [
          [
            "I keep starting this letter and stopping. Not because I don't know what to say, but because every version sounds more certain than I feel.",
          ],
          [
            "The flat is nearly empty now. The plants went to the neighbours, the books to a shop on the corner that still smells of the bakery it used to be. ",
            { c: "anna-home", t: "The city never really felt like home." },
          ],
          [
            "What I miss most is the sound of the kitchen on Sunday mornings, and you arguing with the radio as if it could hear you.",
          ],
          [
            "You'll say I'm running back to something that isn't there anymore, and maybe you're right. Mum's bicycle is still in your hallway, and the man at the market still keeps the bruised pears for whoever asks. ",
            { c: "anna-house", t: "I'm not coming back for the house." },
          ],
          ["I think I'm coming back for the person I was at that kitchen table"],
        ],
        comments: [
          {
            id: "anna-home",
            quote: "The city never really felt like home.",
            text: "The paragraph before is full of things you loved there: the shop, the plants, the neighbours. Is this sentence what you feel, or what's easier to tell her?",
            replies: [
              "That makes sense. A place can be dear without being home. What would it have needed, to become one?",
              "Thank you for putting it so plainly. Which do you want Anna to hear first: the love or the leaving?",
              "I like that you're still turning it over. Is there one small moment from there you'd want her to see?",
            ],
          },
          {
            id: "anna-house",
            quote: "I'm not coming back for the house.",
            text: "This is the first time you say what you're not coming back for. Will Anna want to hear what you are coming back for?",
            replies: [
              "So it's people, not rooms. Does Anna know she's one of them?",
              "That's a lovely distinction. What's the first thing you'd want to do when you get there?",
              "I hear that. Would it help to say it to her as directly as you just said it to me?",
            ],
          },
        ],
      },
      {
        id: "tenants",
        title: "Note to the new tenants",
        goal: "Everything the landlord won't tell them.",
        edited: "2d",
        paragraphs: [
          [
            "Welcome to the flat. I've left the good kettle, the bad lamp and a list of everything that makes a noise at night, so you don't lie awake wondering.",
          ],
          [
            "The radiator in the bedroom knocks twice around six in the morning. It isn't broken. ",
            { c: "tenants-waking", t: "It's just the building waking up before you do." },
          ],
          [
            "Mrs. Becker on the second floor will take in your parcels and then keep them until you've had coffee with her. Say yes at least once. She was the first person here who learned my name.",
          ],
          [
            "The window over the sink sticks in summer. ",
            { c: "tenants-window", t: "Lift it a little before you push, the way you'd help someone up a step." },
          ],
        ],
        comments: [
          {
            id: "tenants-waking",
            quote: "It's just the building waking up before you do.",
            text: "You give the noise a kind reason instead of an explanation. Is that how you'd like them to feel about the whole flat?",
            replies: [
              "That comes through. What's the one thing you'd most like them to love about it?",
              "Nice. Did someone once explain the flat to you this gently?",
              "I can tell. Is there anything here you'd rather they didn't change?",
            ],
          },
          {
            id: "tenants-window",
            quote: "Lift it a little before you push, the way you'd help someone up a step.",
            text: "This is the only instruction that sounds like it's about a person. Who taught you to open it that way?",
            replies: [
              "That's a lovely thing to pass on. Does Mrs. Becker know she's in this note?",
              "So the flat taught you a few manners. Would you tell them who you learned it from?",
              "I like that. Is there a sentence here you'd want to leave for whoever comes after them too?",
            ],
          },
        ],
      },
    ],
  },
  {
    name: "Essays",
    notes: [
      {
        id: "berlin",
        title: "Berlin, in winter",
        goal: "Why I stayed longer than I meant to.",
        edited: "1w",
        paragraphs: [
          [
            "I came to Berlin for three months, in a January so grey the sky looked as if it had been left out overnight. Everyone told me to wait for summer. I'm glad I didn't.",
          ],
          [
            "In winter the city stops performing. The terraces fold up, the canals go still, and people walk home along the Landwehrkanal with their hands deep in their pockets, not in a hurry, just in their own weather. ",
            { c: "berlin-impressive", t: "It's the first place I've lived that doesn't ask me to be impressive." },
          ],
          [
            "On Sundays the shops are shut and the whole city seems to agree to sit down. I learned to buy bread on Saturday, to keep a candle on the windowsill, and to call friends instead of making plans.",
          ],
          [
            "By March I'd stopped counting the weeks. ",
            { c: "berlin-myself", t: "I don't think I fell in love with Berlin. I think I got used to being myself in it." },
          ],
        ],
        comments: [
          {
            id: "berlin-impressive",
            quote: "It's the first place I've lived that doesn't ask me to be impressive.",
            text: "You describe the city mostly by what it doesn't ask of you. What's one thing it gave you, rather than spared you?",
            replies: [
              "That's specific and warm. Could that be where the essay starts?",
              "I love that. Was there a day you noticed it for the first time?",
              "Lovely. Do you think a summer visitor would ever see that side of it?",
            ],
          },
          {
            id: "berlin-myself",
            quote: "I don't think I fell in love with Berlin. I think I got used to being myself in it.",
            text: "This feels like the essay's real sentence. Did you know it when you started, or did the paragraphs lead you here?",
            replies: [
              "That's often how it goes. Would the opening change, now that you know where it ends?",
              "Then it earned its place. Is there a small moment from that first January that shows it?",
              "That's honest. What does being yourself there look like on an ordinary Tuesday?",
            ],
          },
        ],
      },
      {
        id: "bakery",
        title: "The bakery on Linden Street",
        goal: "What a place remembers.",
        edited: "3w",
        paragraphs: [
          [
            "The bakery closed the spring I turned eleven, but the street kept it for years. On damp mornings you could still smell cardamom on the corner, long after the ovens had gone.",
          ],
          [
            "Mr. Lindqvist ",
            { c: "bakery-weighed", t: "cut every loaf with the same knife and never once weighed anything" },
            ". My mother said he measured by looking at you.",
          ],
          [
            "Now it's a bookshop. The counter stands where the shelves of rye used to be, and the owner keeps a bowl of sugar cubes by the till without knowing why. ",
            { c: "bakery-told", t: "I've never told her." },
          ],
        ],
        comments: [
          {
            id: "bakery-weighed",
            quote: "cut every loaf with the same knife and never once weighed anything",
            text: "A wonderful detail. Do you remember what he looked at, when he looked at you?",
            replies: [
              "That's a lovely image. Did you ever see him get it wrong?",
              "Your readers will feel that. What did he give you, the day you went in alone?",
              "I can picture it. Did your mother ever try his trick herself?",
            ],
          },
          {
            id: "bakery-told",
            quote: "I've never told her.",
            text: "The whole essay seems to lead to this. Why haven't you?",
            replies: [
              "That makes sense. Is this essay a way of telling her after all?",
              "Fair enough. What do you think she'd do with the sugar cubes if she knew?",
              "I understand. Would the ending change if you did tell her?",
            ],
          },
        ],
      },
    ],
  },
];

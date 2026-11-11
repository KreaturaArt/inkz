// Replays one action line against a story and records what the host would observe.
// The action script format is documented in test/ground_truth/README.md.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;
using Ink.Runtime;

sealed class Transcript
{
    const int TurnsMax = 200;
    readonly Story story;
    readonly List<string> errors = new List<string>();
    readonly List<string> warnings = new List<string>();

    public Transcript(Story story)
    {
        this.story = story;
        // ink seeds from the clock; ground truth must not.
        story.state.storySeed = 0;
        story.state.previousRandom = 0;
        story.onError += (message, type) =>
        {
            if (type == Ink.ErrorType.Warning) warnings.Add(message);
            else errors.Add(message);
        };
    }

    public void Apply(string action, StringBuilder output)
    {
        var parts = action.Split(' ', 2);
        var argument = parts.Length > 1 ? parts[1] : "";
        switch (parts[0])
        {
            case "seed":
                story.state.storySeed = ParseInt(argument);
                story.state.previousRandom = 0;
                break;
            case "continue":
                ContinueOnce(output);
                break;
            case "continue_maximally":
                while (story.canContinue) ContinueOnce(output);
                break;
            case "choices":
                WriteChoices(output);
                break;
            case "choose":
                story.ChooseChoiceIndex(ParseInt(argument));
                break;
            case "play":
                Play(output);
                break;
            default:
                throw new ArgumentException($"unknown action '{action}'");
        }
        FlushMessages(output);
    }

    void ContinueOnce(StringBuilder output)
    {
        if (!story.canContinue)
        {
            output.Append("can_continue: false\n");
            return;
        }
        var text = story.Continue();
        output.Append("text: ").Append(Json(text)).Append('\n');
        if (story.currentTags.Count > 0) output.Append("tags: ").Append(JsonList(story.currentTags)).Append('\n');
        FlushMessages(output);
    }

    void WriteChoices(StringBuilder output)
    {
        output.Append("choices: ").Append(story.currentChoices.Count).Append('\n');
        foreach (var choice in story.currentChoices)
        {
            output.Append("  ").Append(choice.index).Append(": ").Append(Json(choice.text));
            if (choice.tags != null && choice.tags.Count > 0) output.Append(" tags ").Append(JsonList(choice.tags));
            output.Append('\n');
        }
    }

    // Continues maximally and picks the first choice, until the story ends or TurnsMax turns.
    void Play(StringBuilder output)
    {
        for (var turn = 0; turn < TurnsMax; turn += 1)
        {
            while (story.canContinue) ContinueOnce(output);
            WriteChoices(output);
            if (story.currentChoices.Count == 0)
            {
                output.Append("end\n");
                return;
            }
            output.Append("choose: 0\n");
            story.ChooseChoiceIndex(0);
        }
        output.Append("turns_max reached\n");
    }

    void FlushMessages(StringBuilder output)
    {
        foreach (var error in errors) output.Append("error: ").Append(Json(error)).Append('\n');
        foreach (var warning in warnings) output.Append("warning: ").Append(Json(warning)).Append('\n');
        errors.Clear();
        warnings.Clear();
    }

    static int ParseInt(string text) => int.Parse(text.Trim(), CultureInfo.InvariantCulture);

    static string JsonList(List<string> items)
    {
        var builder = new StringBuilder("[");
        for (var index = 0; index < items.Count; index += 1)
        {
            if (index > 0) builder.Append(", ");
            builder.Append(Json(items[index]));
        }
        return builder.Append(']').ToString();
    }

    public static string Json(string text)
    {
        var builder = new StringBuilder("\"");
        foreach (var character in text)
        {
            switch (character)
            {
                case '"': builder.Append("\\\""); break;
                case '\\': builder.Append("\\\\"); break;
                case '\n': builder.Append("\\n"); break;
                case '\r': builder.Append("\\r"); break;
                case '\t': builder.Append("\\t"); break;
                default:
                    if (character < 0x20) builder.Append("\\u").Append(((int)character).ToString("x4"));
                    else builder.Append(character);
                    break;
            }
        }
        return builder.Append('"').ToString();
    }
}

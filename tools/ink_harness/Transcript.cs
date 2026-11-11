// Replays one action line against a story and records what the host would observe.
// The action script format is documented in test/ground_truth/README.md.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;
using System.Text.Json;
using Ink.Runtime;

sealed class StopTranscript : Exception
{
}

sealed class Transcript
{
    const int TurnsMax = 200;
    readonly string json;
    Story story;
    readonly List<string> errors = new List<string>();
    readonly List<string> warnings = new List<string>();
    readonly List<string> events = new List<string>();
    string lastSave;

    public Transcript(string json)
    {
        this.json = json;
        Attach(new Story(json));
    }

    // Starts observing `fresh`, which replaces the current story (for `load_fresh`).
    void Attach(Story fresh)
    {
        story = fresh;
        // ink seeds from the clock; ground truth must not.
        story.state.storySeed = 0;
        story.state.previousRandom = 0;
        story.onError += (message, type) =>
        {
            if (type == Ink.ErrorType.Warning) warnings.Add(message);
            else errors.Add(message);
        };
    }

    // Applies one action. Throws StopTranscript after recording an exception from ink, whose
    // state is undefined afterwards.
    public void Apply(string action, StringBuilder output)
    {
        try
        {
            ApplyUnchecked(action, output);
        }
        catch (StoryException exception)
        {
            FlushMessages(output);
            output.Append("exception: ").Append(Json(exception.Message)).Append('\n');
            throw new StopTranscript();
        }
        FlushMessages(output);
    }

    void ApplyUnchecked(string action, StringBuilder output)
    {
        var parts = action.Split(' ', 2);
        var argument = parts.Length > 1 ? parts[1].Trim() : "";
        switch (parts[0])
        {
            case "seed":
                story.state.storySeed = ParseInt(argument);
                story.state.previousRandom = 0;
                break;
            case "continue": ContinueOnce(output); break;
            case "continue_maximally": ContinueMaximally(output); break;
            case "choices": WriteChoices(output); break;
            case "choose": story.ChooseChoiceIndex(ParseInt(argument)); break;
            case "play": Play(output); break;
            case "choose_path": story.ChoosePathString(argument); break;
            case "evaluate": Evaluate(argument, output); break;
            case "get": Line(output, "value", Value(story.variablesState[argument])); break;
            case "set": Set(argument); break;
            case "observe": Observe(argument); break;
            case "bind": Bind(argument); break;
            case "unbind": story.UnbindExternalFunction(argument); break;
            case "fallbacks": story.allowExternalFunctionFallbacks = argument == "on"; break;
            case "save": Save(output); break;
            case "load": story.state.LoadJson(lastSave); break;
            case "load_fresh":
                // A new story from the same JSON, as when a game restarts and loads a save.
                Attach(new Story(json));
                story.state.LoadJson(lastSave);
                break;
            case "current_text": Line(output, "current_text", Json(story.currentText)); break;
            case "reset": story.ResetState(); break;
            case "switch_flow": story.SwitchFlow(argument); break;
            case "remove_flow": story.RemoveFlow(argument); break;
            case "default_flow": story.SwitchToDefaultFlow(); break;
            case "visit_count":
                Line(output, "visit_count", story.state.VisitCountAtPathString(argument).ToString());
                break;
            case "tags_at": Line(output, "tags", JsonList(story.TagsForContentAtPath(argument))); break;
            case "global_tags": Line(output, "tags", JsonList(story.globalTags)); break;
            default: throw new ArgumentException($"unknown action '{action}'");
        }
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
        if (story.currentTags.Count > 0) Line(output, "tags", JsonList(story.currentTags));
        FlushMessages(output);
    }

    void ContinueMaximally(StringBuilder output)
    {
        while (story.canContinue) ContinueOnce(output);
    }

    void WriteChoices(StringBuilder output)
    {
        output.Append("choices: ").Append(story.currentChoices.Count).Append('\n');
        foreach (var choice in story.currentChoices)
        {
            output.Append("  ").Append(choice.index).Append(": ").Append(Json(choice.text));
            if (choice.tags != null && choice.tags.Count > 0)
            {
                output.Append(" tags ").Append(JsonList(choice.tags));
            }
            output.Append('\n');
        }
    }

    // Continues maximally and picks the first choice, until the story ends or TurnsMax turns.
    void Play(StringBuilder output)
    {
        for (var turn = 0; turn < TurnsMax; turn += 1)
        {
            ContinueMaximally(output);
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

    // evaluate <function> [<typed value>...]
    void Evaluate(string argument, StringBuilder output)
    {
        var tokens = new Tokens(argument);
        var name = tokens.Word();
        var arguments = new List<object>();
        while (!tokens.AtEnd) arguments.Add(tokens.TypedValue());
        var result = story.EvaluateFunction(name, out var text, arguments.ToArray());
        Line(output, "text", Json(text));
        Line(output, "result", Value(result));
    }

    // set <variable> <typed value>
    void Set(string argument)
    {
        var tokens = new Tokens(argument);
        var name = tokens.Word();
        story.variablesState[name] = tokens.TypedValue();
    }

    void Observe(string name)
    {
        story.ObserveVariable(name, (variable, value) =>
        {
            events.Add($"observed: {variable} = {Value(value)}");
        });
    }

    // bind <function> <behaviour> [lookahead_unsafe]
    //   record              records the call and returns nothing
    //   return <value>      records the call and returns a typed value
    //   multiply            returns the product of its numeric arguments
    //   repeat              (int n, string s) returns s repeated n times
    //   increment_and_evaluate <ink function>
    //                       (int x) returns EvaluateFunction(<ink function>, x + 1)
    void Bind(string argument)
    {
        var tokens = new Tokens(argument);
        var name = tokens.Word();
        var behaviour = tokens.Word();
        object constant = behaviour == "return" ? tokens.TypedValue() : null;
        var inkFunction = behaviour == "increment_and_evaluate" ? tokens.Word() : null;
        var lookaheadSafe = tokens.AtEnd || tokens.Word() != "lookahead_unsafe";
        story.BindExternalFunctionGeneral(name, arguments =>
        {
            var rendered = new List<string>();
            foreach (var value in arguments) rendered.Add(Value(value));
            events.Add($"external: {name}({string.Join(", ", rendered)})");
            switch (behaviour)
            {
                case "record": return null;
                case "return": return constant;
                case "multiply": return Multiply(arguments);
                case "repeat":
                    var repeated = new StringBuilder();
                    for (var i = 0; i < Convert.ToInt32(arguments[0]); i += 1)
                    {
                        repeated.Append(arguments[1]);
                    }
                    return repeated.ToString();
                case "increment_and_evaluate":
                    return story.EvaluateFunction(inkFunction, Convert.ToInt32(arguments[0]) + 1);
                default: throw new ArgumentException($"unknown behaviour '{behaviour}'");
            }
        }, lookaheadSafe);
    }

    static object Multiply(object[] arguments)
    {
        var anyFloat = false;
        foreach (var value in arguments) anyFloat |= value is float;
        if (anyFloat)
        {
            float product = 1;
            foreach (var value in arguments) product *= Convert.ToSingle(value);
            return product;
        }
        var whole = 1;
        foreach (var value in arguments) whole *= Convert.ToInt32(value);
        return whole;
    }

    void Save(StringBuilder output)
    {
        lastSave = story.state.ToJson();
        Line(output, "save", lastSave);
    }

    void FlushMessages(StringBuilder output)
    {
        foreach (var item in events) output.Append(item).Append('\n');
        foreach (var error in errors) Line(output, "error", Json(error));
        foreach (var warning in warnings) Line(output, "warning", Json(warning));
        events.Clear();
        errors.Clear();
        warnings.Clear();
    }

    static void Line(StringBuilder output, string key, string value)
    {
        output.Append(key).Append(": ").Append(value).Append('\n');
    }

    // Renders a host-visible ink value with its type, e.g. `int 5` or `string "a"`.
    public static string Value(object value)
    {
        switch (value)
        {
            case null: return "null";
            case int number: return "int " + number.ToString(CultureInfo.InvariantCulture);
            case float number: return "float " + number.ToString(CultureInfo.InvariantCulture);
            case bool flag: return flag ? "bool true" : "bool false";
            case string text: return "string " + Json(text);
            case InkList list: return "list " + Json(list.ToString());
            default: return "other " + Json(value.ToString());
        }
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

// Splits an action argument into words and typed values (`int 5`, `string "a b"`).
sealed class Tokens
{
    string rest;

    public Tokens(string text)
    {
        rest = text.Trim();
    }

    public bool AtEnd => rest.Length == 0;

    public string Word()
    {
        var space = rest.IndexOf(' ');
        var word = space < 0 ? rest : rest.Substring(0, space);
        rest = space < 0 ? "" : rest.Substring(space + 1).TrimStart();
        if (word.Length == 0) throw new ArgumentException("missing word");
        return word;
    }

    public object TypedValue()
    {
        var type = Word();
        switch (type)
        {
            case "int": return int.Parse(Word(), CultureInfo.InvariantCulture);
            case "float": return float.Parse(Word(), CultureInfo.InvariantCulture);
            case "bool": return Word() == "true";
            case "string": return QuotedString();
            default: throw new ArgumentException($"unknown value type '{type}'");
        }
    }

    string QuotedString()
    {
        var bytes = Encoding.UTF8.GetBytes(rest);
        var reader = new Utf8JsonReader(bytes);
        reader.Read();
        var value = reader.GetString();
        var consumedCharacters = Encoding.UTF8.GetString(bytes, 0, (int)reader.BytesConsumed).Length;
        rest = rest.Substring(consumedCharacters).TrimStart();
        return value;
    }
}

import pytest

from peyda.orchestrator import Cancelled, LoopConfig, Orchestrator, Run
from scripted import Scripted


@pytest.fixture
def orch(gateway, lexicon):
    return Orchestrator(lexicon, gateway, LoopConfig(max_rounds=3, per_service=5, max_services=4))


async def turn(orch, agent, text="cheap samsung phone", history=(), memory=()):
    run = Run(chat_id="c", user="u")
    return run, await orch.turn(run, text, list(history), list(memory), agent)


SATISFIED = {"verdict": "satisfied", "reason": "good spread"}
ANSWER = {"answer": "Here are phones.", "picks": ["shopa:0", "nope:9"], "suggestions": ["cheaper?", "x", "y", "z"]}


async def test_a_first_message_searches_reviews_and_answers(orch):
    agent = Scripted(review=SATISFIED, answer=ANSWER)
    run, out = await turn(orch, agent)
    assert agent.tasks == ["review", "answer"]            # no history: nothing to plan
    assert out["text"] == "Here are phones." and out["suggestions"] == ["cheaper?", "x", "y"]
    assert [c["ref"] for c in out["cards"]] == ["shopa:0"]   # the unknown pick is dropped
    assert out["cards"][0]["source"] == "Shopa" and out["degraded"] is False
    assert out["cards"][0]["title"] == "Samsung Galaxy A55" and out["cards"][0]["price_toman"] == 18_500_000
    assert [e["name"] for e in run.events if e["type"] == "stage"] == ["extract", "search", "review", "answer"]
    assert any(e["type"] == "service" and e["id"] == "shopa" and e["status"] == "ok" for e in run.events)


async def test_the_agent_sees_the_frame_and_results_with_refs_it_can_pick(orch):
    agent = Scripted(review=SATISFIED, answer=ANSWER)
    await turn(orch, agent)
    review = agent.calls[0][1]
    assert review["round"] == 1 and review["results"]["frame"]["domains"] == ["shopping"]
    shop = next(s for s in review["results"]["services"] if s["id"] == "shopa")
    assert shop["status"] == "ok" and shop["hits"][0]["ref"] == "shopa:0" and shop["hits"][0]["price_toman"]
    assert "shopping" in review["domains_available"]


async def test_a_better_query_goes_back_through_gliner_and_iran_mcp(orch):
    agent = Scripted(
        review=[{"verdict": "refine", "reason": "too broad", "query": "samsung galaxy phone under 20 million toman", "exclude_services": ["broken"]}, SATISFIED],
        answer=ANSWER)
    run, out = await turn(orch, agent)
    assert agent.tasks == ["review", "review", "answer"]
    assert [r["query"] for r in out["rounds"]] == ["cheap samsung phone", "samsung galaxy phone under 20 million toman"]
    second = [e for e in run.events if e["type"] == "frame"][1]
    assert second["frame"]["slots"]["price_max_toman"] == 20_000_000    # the refined query was re-read into a frame
    later = [e for e in run.events if e["type"] == "service" and e["round"] == 2]
    assert "broken" not in [e["id"] for e in later]                     # and the directive was honoured
    assert agent.calls[1][1]["earlier_queries"] == ["cheap samsung phone"]


async def test_a_repeated_query_ends_the_loop(orch):
    agent = Scripted(review={"verdict": "refine", "query": "Cheap  samsung phone"}, answer=ANSWER)
    run, out = await turn(orch, agent)
    assert len(out["rounds"]) == 1 and any("repeats" in e.get("text", "") for e in run.events)


async def test_the_round_cap_is_the_servers(orch):
    n = iter(range(100))
    agent = Scripted(review=lambda d: {"verdict": "refine", "query": f"samsung phone {next(n)}"}, answer=ANSWER)
    _, out = await turn(orch, agent)
    assert len(out["rounds"]) == 3 and agent.tasks == ["review", "review", "answer"]


async def test_the_best_round_is_answered_not_merely_the_last(orch):
    agent = Scripted(review=[{"verdict": "refine", "query": "zzz nothing matches"}, SATISFIED], answer=lambda d: ANSWER)
    _, out = await turn(orch, agent)
    answered = agent.calls[-1][1]
    assert answered["query"] == "cheap samsung phone" and answered["rounds"] == 2   # round 2 found nothing


async def test_the_agent_can_ask_the_person_for_what_is_missing(orch):
    agent = Scripted(review={"verdict": "ask_user", "question": "Which day do you want to fly?"})
    _, out = await turn(orch, agent, "flight tehran to mashhad")
    assert out["text"] == "Which day do you want to fly?" and agent.tasks == ["review"]


async def test_a_follow_up_is_planned_with_the_conversation_and_earlier_searches(orch):
    history = [{"role": "user", "content": "cheap samsung phone"}, {"role": "assistant", "content": "Here are phones."}]
    memory = [{"query": "cheap samsung phone", "frame": {"slots": {"brand": "samsung"}}, "top": ["Samsung Galaxy A55"]}]
    agent = Scripted(plan={"action": "search", "query": "cheapest samsung galaxy phone"}, review=SATISFIED, answer=ANSWER)
    _, out = await turn(orch, agent, "and cheaper ones?", history, memory)
    task, data, sent_history = agent.calls[0]
    assert task == "plan" and data["message"] == "and cheaper ones?" and data["earlier_searches"] == memory
    assert sent_history == history                                   # the thread travels with every ask
    assert all(c[2] == history for c in agent.calls)
    assert out["rounds"][0]["query"] == "cheapest samsung galaxy phone"


async def test_a_follow_up_the_conversation_can_answer_runs_no_search(orch):
    agent = Scripted(plan={"action": "reply", "reply": "That was the A55."})
    run, out = await turn(orch, agent, "which one was cheapest?", [{"role": "user", "content": "x"}])
    assert out["text"] == "That was the A55." and out["rounds"] == [] and agent.tasks == ["plan"]
    assert not [e for e in run.events if e["type"] == "service"]


async def test_an_unreachable_agent_degrades_to_the_raw_results_not_an_error(orch):
    agent = Scripted(review=RuntimeError("platform down"), answer=RuntimeError("platform down"))
    _, out = await turn(orch, agent)
    assert out["degraded"] is True and "Samsung Galaxy A55" in out["text"] and out["cards"]
    assert "platform down" in out["degraded_reason"]  # the person can see why, and fix it


async def test_a_healthy_turn_has_no_degraded_reason(orch):
    _, out = await turn(orch, Scripted(review=SATISFIED, answer=ANSWER))
    assert out["degraded"] is False and out["degraded_reason"] == ""


async def test_a_reply_that_is_not_json_is_asked_again_once(orch):
    agent = Scripted(review=["sure, looks fine!", SATISFIED], answer=ANSWER)
    _, out = await turn(orch, agent)
    assert agent.tasks == ["review", "review", "answer"] and out["degraded"] is False


async def test_a_cancelled_run_stops_between_steps(orch):
    run = Run()
    run.cancelled = True
    with pytest.raises(Cancelled):
        await orch.turn(run, "x", [], [], Scripted(review=SATISFIED, answer=ANSWER))


async def test_plain_search_needs_no_agent(orch):
    result = await orch.search("cheap samsung phone", limit=3)
    assert result.total >= 2 and result.frame.domain_names == ["shopping"]

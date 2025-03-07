defmodule EXLA.Defn.APITest do
  use EXLA.Case, async: true

  import Nx.Defn
  import ExUnit.CaptureLog

  defn add_two(a, b), do: a + b

  describe "multi-client" do
    @tag :mlir_token_error
    test "converts from host to separate client" do
      a = Nx.tensor(1, backend: {EXLA.Backend, client: :host})
      b = Nx.tensor(2, backend: {EXLA.Backend, client: :host})

      assert_equal(
        EXLA.jit(&add_two/2, client: :other_host).(a, b),
        Nx.tensor(3)
      )
    end

    @tag :mlir_token_error
    test "converts from host to separate client through lazy transfers" do
      a = Nx.tensor(1, backend: {EXLA.Backend, client: :host})
      b = Nx.tensor(2, backend: {EXLA.Backend, client: :host})

      assert_equal(
        EXLA.jit(&add_two/2, client: :other_host, lazy_transfers: :always).(a, b),
        Nx.tensor(3)
      )
    end
  end

  describe "options" do
    @tag :mlir_token_error
    test "logs when debugging" do
      logs =
        capture_log(fn ->
          EXLA.jit(&add_two/2, debug: true).(2, 3)
        end)

      assert logs =~ ~r"EXLA defn evaluation #Function<[^>]+> cache (hit|miss) in \d+\.\dms"
      assert logs =~ ~r"EXLA compilation #Function<[^>]+> cache (hit|miss) in \d+\.\dms"
      assert logs =~ ~r"EXLA device \d lock in \d+\.\dms"
      assert logs =~ ~r"EXLA execution on device \d in \d+\.\dms"

      logs =
        capture_log(fn ->
          EXLA.jit(&add_two/2, debug: true).(2, 3)
        end)

      assert logs =~ ~r"EXLA defn evaluation #Function<[^>]+> cache hit in \d+\.\dms"
      assert logs =~ ~r"EXLA compilation #Function<[^>]+> cache hit in \d+\.\dms"
      assert logs =~ ~r"EXLA device \d lock in \d+\.\d+ms"
      assert logs =~ ~r"EXLA execution on device \d in \d+\.\dms"
    end
  end

  describe "containers" do
    defn container_as_input(%Container{a: a, b: b}) do
      a * b
    end

    defn update_container(var, x) do
      %{var | b: x}
    end

    defn dot_container(container) do
      container.a * container.b
    end

    defn container_with_map_tuple(%Container{a: {x, y}, b: %{} = b}) do
      %{a: a, b: b} = b
      x * y * a * b
    end

    test "matched as input" do
      inp = %Container{a: Nx.tensor(5), b: Nx.tensor(3)}

      assert_equal(container_as_input(inp), Nx.tensor(15))
    end

    @tag :mlir_not_a_tuple
    test "updated" do
      inp = %Container{a: Nx.tensor(1), b: 2, c: :reset, d: :keep}

      assert %Container{a: a, b: b, c: c, d: d} = update_container(inp, Nx.tensor(8))
      assert_equal(a, Nx.tensor(1))
      assert_equal(b, Nx.tensor(8))
      assert c == nil
      assert d == :keep
    end

    test "can be used with dot syntax" do
      inp = %Container{a: Nx.tensor(1), b: 2}
      assert_equal(dot_container(inp), Nx.tensor(2))
    end

    test "can be used with nested collections" do
      inp = %Container{a: {Nx.tensor(1), Nx.tensor(2)}, b: %{a: Nx.tensor(3), b: Nx.tensor(4)}}
      assert_equal(container_with_map_tuple(inp), Nx.tensor(24))
    end
  end

  describe "batch" do
    test "when padded" do
      input = Nx.tensor([[1, 2, 3]], backend: EXLA.Backend)
      batch = [input] |> Nx.Batch.concatenate() |> Nx.Batch.pad(1)
      predict = Nx.Defn.jit(fn input -> input end, compiler: EXLA)
      assert_equal(predict.(batch), Nx.tensor([[1, 2, 3], [0, 0, 0]]))
    end
  end

  describe "cache" do
    defn merge(init_map) do
      params = init()
      merge_transform(params, init_map)
    end

    deftransformp(merge_transform(params, init_map), do: Map.merge(params, init_map))

    defn init() do
      %{"x" => rand(), "y" => rand()}
    end

    deftransformp rand, do: :rand.uniform()

    test "considers map keys in cache keys" do
      assert_equal(merge(%{"x" => 10})["x"], Nx.tensor(10))
      assert_equal(merge(%{"y" => 10})["y"], Nx.tensor(10))
    end
  end

  describe "stream" do
    defn defn_sum(entry, acc), do: {acc, entry + acc}

    @tag :mlir_token_error
    test "immediately done" do
      stream = EXLA.stream(&defn_sum/2, [0, 0])
      assert %Nx.Tensor{data: %EXLA.Backend{}} = done = Nx.Stream.done(stream)
      assert_equal(Nx.backend_transfer(done), Nx.tensor(0))

      stream = EXLA.stream(&defn_sum/2, [1, 2])
      assert %Nx.Tensor{data: %EXLA.Backend{}} = done = Nx.Stream.done(stream)
      assert_equal(Nx.backend_transfer(done), Nx.tensor(2))
    end

    @tag :mlir_token_error
    test "send/recv" do
      %_{} = stream = EXLA.stream(&defn_sum/2, [0, 0])
      assert Nx.Stream.send(stream, 1) == :ok
      assert_equal(Nx.Stream.recv(stream), Nx.tensor(0))

      assert Nx.Stream.send(stream, 2) == :ok
      assert_equal(Nx.Stream.recv(stream), Nx.tensor(1))

      assert_equal(Nx.Stream.done(stream), Nx.tensor(3))
    end

    @tag :mlir_token_error
    test "send x2/recv x2" do
      %_{} = stream = EXLA.stream(&defn_sum/2, [0, 0])
      assert Nx.Stream.send(stream, 1) == :ok
      assert Nx.Stream.send(stream, 2) == :ok

      assert_equal(Nx.Stream.recv(stream), Nx.tensor(0))
      assert_equal(Nx.Stream.recv(stream), Nx.tensor(1))

      assert_equal(Nx.Stream.done(stream), Nx.tensor(3))
    end

    defn stream_composite(i, {a, {b, c}}) do
      a = a + i
      b = b * i
      c = Nx.pow(c, i)
      {{{a, b}, c}, {a, {b, c}}}
    end

    @tag :mlir_token_error
    test "send/recv with composite types" do
      %_{} = stream = EXLA.stream(&stream_composite/2, [0, {0, {1, 2}}])
      assert Nx.Stream.send(stream, 1) == :ok
      assert_equal(Nx.Stream.recv(stream), {{Nx.tensor(1), Nx.tensor(1)}, Nx.tensor(2)})

      assert Nx.Stream.send(stream, 2) == :ok
      assert_equal(Nx.Stream.recv(stream), {{Nx.tensor(3), Nx.tensor(2)}, Nx.tensor(4)})

      assert_equal(Nx.Stream.done(stream), {Nx.tensor(3), {Nx.tensor(2), Nx.tensor(4)}})
    end

    defn stream_empty_outfeed(i, t), do: {{}, i + t}

    @tag :mlir_token_error
    test "send/recv with empty outfeed" do
      %_{} = stream = EXLA.stream(&stream_empty_outfeed/2, [0, 0])
      assert Nx.Stream.send(stream, 1) == :ok
      assert Nx.Stream.recv(stream) == {}

      assert Nx.Stream.send(stream, 2) == :ok
      assert Nx.Stream.recv(stream) == {}

      assert_equal(Nx.Stream.done(stream), Nx.tensor(3))
    end

    defn stream_empty_acc(i, {}), do: {i * i, {}}

    @tag :mlir_token_error
    test "send/recv with empty acc" do
      %_{} = stream = EXLA.stream(&stream_empty_acc/2, [0, {}])
      assert Nx.Stream.send(stream, 1) == :ok
      assert_equal(Nx.Stream.recv(stream), Nx.tensor(1))

      assert Nx.Stream.send(stream, 2) == :ok
      assert_equal(Nx.Stream.recv(stream), Nx.tensor(4))

      assert Nx.Stream.done(stream) == {}
    end

    @tag :mlir_token_error
    test "handles failure before writing" do
      {_, ref} = spawn_monitor(fn -> EXLA.stream(&defn_sum/2, [0, 0]) end)
      assert_receive {:DOWN, ^ref, _, _, _}

      %_{} = stream = EXLA.stream(&defn_sum/2, [0, 0])
      assert Nx.Stream.send(stream, 1) == :ok
      assert_equal(Nx.Stream.recv(stream), Nx.tensor(0))
      assert_equal(Nx.Stream.done(stream), Nx.tensor(1))
    end

    @tag :mlir_token_error
    test "handles failure after writing" do
      {_, ref} =
        spawn_monitor(fn ->
          stream = EXLA.stream(&defn_sum/2, [0, 0])
          assert Nx.Stream.send(stream, 1) == :ok
        end)

      assert_receive {:DOWN, ^ref, _, _, _}

      %_{} = stream = EXLA.stream(&defn_sum/2, [0, 0])
      assert Nx.Stream.send(stream, 1) == :ok
      assert_equal(Nx.Stream.recv(stream), Nx.tensor(0))
      assert_equal(Nx.Stream.done(stream), Nx.tensor(1))
    end

    @tag :mlir_token_error
    test "raises if recv is pending on done" do
      %_{} = stream = EXLA.stream(&defn_sum/2, [0, 0])
      assert Nx.Stream.send(stream, 1) == :ok

      assert_raise RuntimeError,
                   "cannot mark stream as done when there are recv messages pending",
                   fn -> Nx.Stream.done(stream) end
    end

    @tag :mlir_token_error
    test "raises if stream is done when recving" do
      %_{} = stream = EXLA.stream(&defn_sum/2, [0, 0])
      assert_equal(Nx.Stream.done(stream), Nx.tensor(0))

      assert_raise RuntimeError,
                   "cannot recv from stream because it has been terminated",
                   fn -> Nx.Stream.recv(stream) end
    end

    defn container_stream(%Container{a: a} = elem, %Container{b: b} = acc) do
      {%{elem | a: a + b}, %{acc | b: a + b}}
    end

    @tag :mlir_token_error
    test "container in and out" do
      args = [%Container{a: 0, b: 0, c: :reset, d: :elem}, %Container{a: 0, b: 0, d: :acc}]
      %_{} = stream = EXLA.stream(&container_stream/2, args)

      assert Nx.Stream.send(stream, %Container{a: 1, b: -1}) == :ok

      assert_equal(Nx.Stream.recv(stream), %Container{a: Nx.tensor(1), b: Nx.tensor(-1), d: :elem})

      assert Nx.Stream.send(stream, %Container{a: 2, b: -2}) == :ok

      assert_equal(Nx.Stream.recv(stream), %Container{a: Nx.tensor(3), b: Nx.tensor(-2), d: :elem})

      assert_equal(Nx.Stream.done(stream), %Container{a: Nx.tensor(0), b: Nx.tensor(3), d: :acc})
    end

    defn lazy_container_stream(%LazyWrapped{a: a, c: c}, acc) do
      {acc, acc + a - c}
    end

    @tag :mlir_token_error
    test "lazy container in" do
      args = [%LazyOnly{a: 0, b: 0, c: 0}, 0]
      %_{} = stream = EXLA.stream(&lazy_container_stream/2, args)

      assert Nx.Stream.send(stream, %LazyOnly{a: 3, b: 0, c: -1}) == :ok
      assert_equal(Nx.Stream.recv(stream), Nx.tensor(0))

      assert Nx.Stream.send(stream, %LazyOnly{a: 5, b: 0, c: 2}) == :ok
      assert_equal(Nx.Stream.recv(stream), Nx.tensor(4))

      assert_equal(Nx.Stream.done(stream), Nx.tensor(7))
    end
  end

  describe "hooks" do
    require Logger

    defp send_to_self(tag) do
      parent = self()
      fn value -> send(parent, {tag, value}) end
    end

    defn hook_default(a, b) do
      hook(a + b, :default, send_to_self(:default))
    end

    @tag :mlir_token_error
    test "executes hook with default" do
      assert hook_default(2, 3)
      assert_receive {:default, tensor}
      assert_equal(tensor, Nx.tensor(5))
    end

    @tag :mlir_token_error
    test "executes hook with callback" do
      assert_equal(
        EXLA.jit(&hook_default/2, hooks: %{default: send_to_self(:tag)}).(2, 3),
        Nx.tensor(5)
      )

      assert_receive {:tag, tensor}
      assert_equal(tensor, Nx.tensor(5))

      # Executing again with another tag works
      assert_equal(
        EXLA.jit(&hook_default/2, hooks: %{default: send_to_self(:another_tag)}).(2, 3),
        Nx.tensor(5)
      )

      assert_receive {:another_tag, tensor}
      assert_equal(tensor, Nx.tensor(5))
    end

    defn hook_optional(a, b) do
      hook(a + b, :optional)
    end

    @tag :mlir_token_error
    test "executes optional hook" do
      assert_equal(hook_optional(2, 3), Nx.tensor(5))

      assert_equal(
        EXLA.jit(&hook_optional/2, hooks: %{optional: send_to_self(:tag)}).(2, 3),
        Nx.tensor(5)
      )

      assert_receive {:tag, tensor}
      assert_equal(tensor, Nx.tensor(5))
    end

    defn hook_factorial(x) do
      {factorial, _} =
        while {factorial = 1.0, x}, Nx.greater(x, 1) do
          hook({factorial * x, x - 1}, :factorial)
        end

      factorial
    end

    @tag :mlir_token_error
    test "executes hook within while" do
      assert_equal(
        EXLA.jit(&hook_factorial/1, hooks: %{factorial: send_to_self(:tag)}).(5),
        Nx.tensor(120.0)
      )

      assert_received {:tag, tuple}
      assert tuple == {Nx.tensor(5.0), Nx.tensor(4)}
      assert_received {:tag, tuple}
      assert tuple == {Nx.tensor(20.0), Nx.tensor(3)}
      assert_received {:tag, tuple}
      assert tuple == {Nx.tensor(60.0), Nx.tensor(2)}
      assert_received {:tag, tuple}
      assert tuple == {Nx.tensor(120.0), Nx.tensor(1)}
    end

    defn hook_cond(a, b) do
      cond do
        a == -1 -> hook(b * 2, :cond)
        a == 1 -> hook(b / 2, :cond)
        true -> hook(Nx.pow(b, 2), :cond)
      end
    end

    @tag :mlir_token_error
    test "executes hook within cond" do
      assert_equal(
        EXLA.jit(&hook_cond/2, hooks: %{cond: send_to_self(:tag)}).(1, 4),
        Nx.tensor(2.0)
      )

      assert_received {:tag, tensor}
      assert_equal(tensor, Nx.tensor(2.0))

      assert_equal(
        EXLA.jit(&hook_cond/2, hooks: %{cond: send_to_self(:tag)}).(-1, 4),
        Nx.tensor(8.0)
      )

      assert_received {:tag, tensor}
      assert_equal(tensor, Nx.tensor(8))

      assert_equal(
        EXLA.jit(&hook_cond/2, hooks: %{cond: send_to_self(:tag)}).(0, 4),
        Nx.tensor(16.0)
      )

      assert_received {:tag, tensor}
      assert_equal(tensor, Nx.tensor(16))
    end

    defn hook_container(container) do
      hook(container, :container)
    end

    @tag :mlir_token_error
    test "executes hook with container" do
      container = %Container{a: 1, b: 2, c: :reset, d: :elem}
      EXLA.jit(&hook_container/1, hooks: %{container: send_to_self(:tag)}).(container)

      assert_receive {:tag, %Container{a: a, b: b, c: nil, d: :elem}}
      assert_equal(a, Nx.tensor(1))
      assert_equal(b, Nx.tensor(2))
    end

    defn hook_stream(entry, acc), do: hook({acc, entry + acc}, :stream)

    @tag :mlir_token_error
    test "executes hook with stream" do
      %_{} = stream = EXLA.stream(&hook_stream/2, [0, 0], hooks: %{stream: send_to_self(:tag)})
      assert Nx.Stream.send(stream, 1) == :ok
      assert_equal(Nx.Stream.recv(stream), Nx.tensor(0))
      assert_receive {:tag, {previous_acc, new_acc}}
      assert_equal(previous_acc, Nx.tensor(0))
      assert_equal(new_acc, Nx.tensor(1))
      refute_received _

      assert Nx.Stream.send(stream, 2) == :ok
      assert_equal(Nx.Stream.recv(stream), Nx.tensor(1))
      assert_receive {:tag, {previous_acc, new_acc}}
      assert_equal(previous_acc, Nx.tensor(1))
      assert_equal(new_acc, Nx.tensor(3))
      refute_received _

      assert_equal(Nx.Stream.done(stream), Nx.tensor(3))
      refute_received _
    end
  end

  describe "telemetry" do
    defn telemetry_add_two(a, b), do: a + b

    def telemetry_handler(_event_name, measurements, metadata, _config) do
      send(self(), {measurements, metadata})
    end

    test "executes event when function is compiled" do
      :ok =
        :telemetry.attach(__MODULE__, [:exla, :compilation], &__MODULE__.telemetry_handler/4, nil)

      on_exit(fn -> :telemetry.detach(__MODULE__) end)

      fun = &telemetry_add_two/2
      EXLA.jit(fun).(2, 3)
      assert_received {measurements, metadata}

      assert %{compile_time: compile_time, eval_time: eval_time, total_time: total_time} =
               measurements

      assert metadata == %{key: fun}

      assert is_integer(compile_time)
      assert eval_time > 0
      assert is_integer(eval_time)
      assert compile_time > 0
      assert total_time == compile_time + eval_time

      EXLA.jit(fun).(4, 5)
      refute_received _

      a = Nx.tensor([1, 2])
      b = Nx.tensor([3, 4])
      EXLA.jit(fun).(a, b)

      assert_received {measurements, metadata}

      assert %{compile_time: compile_time, eval_time: eval_time, total_time: total_time} =
               measurements

      assert metadata == %{key: fun}

      assert is_integer(compile_time)
      assert eval_time > 0
      assert is_integer(eval_time)
      assert compile_time > 0
      assert total_time == compile_time + eval_time
    end
  end
end

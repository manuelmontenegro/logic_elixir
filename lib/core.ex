defmodule Core do
  @moduledoc """
  Documentation for Core module.
  """
  import Unification, only: [unify: 3]
  require Logger

  #########
  # Types #
  #########

  # delta is a map that relates Logic vars with Elixir terms
  # TODO add delta type

  ##########
  # Guards #
  ##########

  ##########
  # Macros #
  ##########

  defmacro __before_compile__(_env) do
    VarBuilder.start_link()
  end

  defmacro defcore(pred_name, [do: do_block]) do
    # Loger.info("pred_name: #{inspect(pred_name)}")
    fun = tr_def(pred_name, do_block)
    quote do
      unquote(fun)#.(%{}) |> Enum.into([])
    end

    # # Loger.info("a: #{inspect(a)}")
    # # Loger.info("b: #{inspect(b)}")
    # # Loger.info("c: #{inspect(c)}")
    # Loger.info("fun: #{inspect(fun)}")
    Macro.to_string(fun) |> IO.puts
    # c |> Macro.to_string
  end

  #############
  # Functions #
  #############

  # def tr_def({:defcore, _metadata, [predicate_name_node, [do: do_block]]}) do
  #   {predicate_name, [], predicate_args} = predicate_name_node

  def tr_def(predicate_name_node, do_block) do
    {predicate_name, _metadata, predicate_args} = predicate_name_node

    goals =
      case do_block do
        {:__block__, [], do_stmts} -> do_stmts
        _ -> [do_block]
      end

    logic_vars =
      Enum.map(predicate_args, fn {:__aliases__, _metadata, [logic_var]} -> logic_var end)

    {t_list, x_list} =
      case predicate_args do
        [] ->
          {[], []}

        _ ->
          {
            Enum.map(1..length(predicate_args), fn t ->
              String.to_atom("t#{t}") |> Macro.unique_var(__MODULE__)
            end),
            Enum.map(1..length(predicate_args), fn x ->
              String.to_atom("x#{x}") |> Macro.unique_var(__MODULE__)
            end)
          }
      end

    vars_goals = goals |> vars() |> Enum.filter(fn var -> not Enum.member?(logic_vars, var) end)


    y_list =
      case vars_goals do
        [] ->
          []

        _ ->
          1..length(vars_goals)
          |> Enum.map(fn y -> String.to_atom("y#{y}") |> Macro.unique_var(__MODULE__) end)
      end

    delta_keys = :lists.flatten([logic_vars, vars_goals])
    delta_values = :lists.flatten([x_list, y_list])
    delta = Enum.zip(delta_keys, delta_values) |> Enum.into(%{})

    gen_var = "VarBuilder.gen_var" |> String.to_atom() |> Macro.unique_var(__MODULE__)

    quote do
      def unquote({predicate_name, [], t_list}) do
        unquote({:__block__, [], x_list |> Enum.map(fn x -> {:=, [], [x, gen_var]} end)})
        unquote({:__block__, [], y_list |> Enum.map(fn y -> {:=, [], [y, gen_var]} end)})

        fn th1 ->
          th2 = Map.merge(th1, Map.new(unquote(Enum.zip(x_list, t_list))))

          unquote(tr_goals(delta, goals)).(th2)
          |> Stream.map(&Map.drop(&1, unquote(List.flatten([x_list, y_list]))))
        end
      end
    end
  end

  def tr_goals(_delta, []) do
    quote do
      fn th -> [th] end
    end
  end

  def tr_goals(delta, [goal | goals]) do
    quote do
      fn th1 ->
        unquote(tr_goal(delta, goal)).(th1)
        |> Stream.flat_map(fn th2 -> unquote(tr_goals(delta, goals)).(th2) end)
      end
    end
  end

  def tr_goal(delta, {:=, _metadata, [t1, t2]}) do
    th = Macro.unique_var(:th, __MODULE__)
    term1 = tr_term(delta, th, t1)
    term2 = tr_term(delta, th, t2)

    quote do
      fn unquote(th) ->
        unify_gen(th, unquote(term1), unquote(term2))
      end
    end
  end

  def tr_goal(delta, {:choice, _metadata, [choice_block]}) do
    th = Macro.unique_var(:th, __MODULE__)
    goals = choice_goals(delta, choice_block)

    quote do
      fn unquote(th) ->
        unquote(goals) |> Stream.flat_map(fn f -> f.(th) end)
      end
    end
  end

  # TODO verify proper behavior
  def tr_goal(delta, {:@, _metadata, [at_arguments]}) do
    th = Macro.unique_var(:th, __MODULE__)
    check_b = "check_b" |> String.to_atom |> Macro.unique_var(__MODULE__)
    groundify = "groundify" |> String.to_atom() |> Macro.unique_var(__MODULE__)

    quote do
      fn unquote(th) ->
        unquote({check_b, [], [th, {groundify, [], [th, tr_term(delta, th, at_arguments)]}]})
      end
    end
  end

  def tr_goal(delta, {predicate_name, _metadata, args}) do
    th = Macro.unique_var(:th, __MODULE__)
    tr_term_args = Enum.map(args, fn arg -> tr_term(delta, th, arg) end)

    quote do
      fn unquote(th) ->
        unquote({predicate_name, [], tr_term_args}).(th)
      end
    end
  end

  def tr_term(delta, _x, {:__aliases__, _metadata, [logic_var]}), do: {:var, delta[logic_var]}

  def tr_term(delta, x, {function_name, _metadata, arguments}) do
    x_args = case arguments do
      [] -> %{}
      _ ->
        1..length(arguments)
        |>
        Enum.map(fn x ->
          String.to_atom("x#{x}") |> Macro.unique_var(__MODULE__) end)
        |>
        Enum.zip(arguments)
        |>
        Enum.into(%{})
    end

    xs = x_args |> Map.keys
    groundify = "groundify" |> String.to_atom() |> Macro.unique_var(__MODULE__)
    quote do
      unquote({:__block__, [], x_args |> Enum.map(fn {xx, tx} ->
                                                    {:=, [], [xx, {groundify, [], [x, tr_term(delta, x, tx)]}]}
                                                  end)
      })
      unquote({:ground, {function_name, [], xs}})
    end
  end

  def tr_term(_delta, _x, []), do: []

  def tr_term(delta, x, [{:|, _metadata, [t, sublist]}]) do
    head = tr_term(delta, x, t)
    tail = case sublist do
      [{:|, [], _}] -> tr_term(delta, x, sublist)
      [tx] -> tr_term(delta, x, tx)
      _ -> tr_term(delta, x, sublist)
    end
    List.flatten([head, tail])
  end

  def tr_term(delta, x, [h | t]) do
    head = tr_term(delta, x, h)
    tail = tr_term(delta, x, t)
    build_list = "build_list" |> String.to_atom |> Macro.unique_var(__MODULE__)
    quote do
      unquote({build_list, [], [head, tail]})
    end
  end

  def tr_term(delta, x, tuple) when is_tuple(tuple) do
    list = tuple |> Tuple.to_list() |> Enum.map(fn tx -> tr_term(delta, x, tx) end)
    build_tuple = "build_tuple" |> String.to_atom |> Macro.unique_var(__MODULE__)
    quote do
      unquote({build_tuple, [], [list]})
    end
  end

  def tr_term(_delta, _x, lit), do: {:ground, lit}

  def unify_gen(theta, t1, t2) do
    case unify(t1, t2, theta) do
      :unmatch -> []
      theta2 -> [theta2]
    end
  end

  def check_b(_, false), do: []
  def check_b(_, nil), do: []
  def check_b(theta, _), do: [theta]

  def build_tuple(terms) do
    if Enum.all?(terms, &match?({:ground, _}, &1)) do
      {:ground,
        terms
        |> Enum.map(fn {:ground, t} -> t end)
        |> List.to_tuple() }
    else
      List.to_tuple(terms)
    end
  end

  def build_list({:ground, h}, {:ground, t}), do: {:ground, [h | t]}
  def build_list(h, t), do: [h | t]

  def groundify(_theta, {:ground, t}), do: t

  def groundify(theta, {:var, x}) when is_map_key(theta, x) do
    case theta[x] do
      {:ground, t} -> t
      _ -> throw "#{x} is not bound to a fully instatiated term"
    end
  end

  def groundify(_theta, {:var, x}) do
    throw "#{x} is not instantiated"
  end

  def groundify(theta, t) when is_tuple(t) do
    t
    |> Tuple.to_list()
    |> Enum.map(&groundify(theta, &1))
    |> List.to_tuple()
  end

  def groundify(theta, [t1 | t2]) do
    [groundify(theta, t1) | groundify(theta, t2)]
  end

  #####################
  ##### EXAMPLES ######
  #####################

  # Execution:
  # iex -S mix
  # VarBuilder.start_link
  # Core.p9 |> Core.tr_def |> Macro.to_string |> IO.puts

  def p1 do
    quote do
      defcore pred1(X) do
        X = 5
      end
    end
  end

  def p2 do
    quote do
      defcore pred2(X, Y) do
        X = 5
        Y = 6
      end
    end
  end

  def p3 do
    quote do
      defcore pred3(X, Y) do
        X = Z
        Y = Z
      end
    end
  end

  def p4 do
    quote do
      defcore pred4(X) do
        Z = X
      end
    end
  end

  def p5 do
    quote do
      defcore pred5() do
        Z = 1
      end
    end
  end

  def p6 do
    quote do
      defcore pred6(X) do
        choice do
          X = 1
        else
          X = 2
        end
      end
    end
  end

  def p7 do
    quote do
      defcore pred7(X) do
        choice do
          X = 1
        else
          X = 2
        else
          X = 3
        end
      end
    end
  end

  def p8 do
    quote do
      defcore pred8(X, Y) do
        choice do
          X = 1
        else
          X = 2
        end

        Y = 3
      end
    end
  end

  def p9 do
    quote do
      defcore pred9(X, Y) do
        choice do
          X = 1
          Y = 3
        else
          X = 2
          Y = 4
        end
      end
    end
  end

  # TODO fix the code to pass this function
  def p10 do
    quote do
      defcore append(Xs, Ys, Zs) do
        choice do
          Xs = []
          Ys = Zs
        else
          Xs = [X | XX]
          Zs = [X | ZZ]
          append(XX, Ys, ZZ)
        end
      end
    end
  end

  def p11 do
    quote do
      defcore pred11() do
        X = [X1 | X2]
      end
    end
  end

  def p110 do
    quote do
      defcore pred110(X) do
        X = [X1 | X2]
      end
    end
  end

  def p12 do
    quote do
      defcore pred12() do
        pred1(1)
      end
    end
  end

  def p13 do
    quote do
      defcore pred13(X) do
        pred1(X)
      end
    end
  end

  def g(x, y), do: x + y

  def p14 do
    quote do
      defcore pred14(Z) do
        X = 3
        Y = 4
        Z = g(X, Y)
      end
    end
  end

  def p140 do
    quote do
      defcore pred140(Z) do
        X = 3
        Y = W
        Z = g(X, Y)
      end
    end
  end

  def p141 do
    quote do
      defcore pred141(Z) do
        X = 3
        Y = W
        W = 15
        Z = g(X, Y)
      end
    end
  end

  def p15 do
    quote do
      defcore pred15() do
        @(X)
      end
    end
  end

  def p16 do
    quote do
      defcore pred16(X, Y) do
        {X, Y} = {1, 2}
      end
    end
  end

  def p17 do
    quote do
      defcore pred17(X, Y) do
        {Z, T} = {X, Y}
      end
    end
  end

  def p18 do
    quote do
      defcore pred18(X, Y) do
        choice do
          {X, Y} = {1, 3}
        else
          {X, Y} = {2, 4}
        end
      end
    end
  end

  def p19 do
    quote do
      defcore pred19() do
        pred1(X)
      end
    end
  end

  def p20 do
    quote do
      defcore pred20(X) do
        X = {Y, Z}
      end
    end
  end

  def p21 do
    quote do
      defcore pred21(X) do
        X = [1, 2, 3]
      end
    end
  end

  def p22 do
    quote do
      defcore pred22(X, Y, Z) do
        [X, Y, Z] = [1, 2, 3]
      end
    end
  end

  def p23 do
    quote do
      defcore pred23() do
        [X, Y, Z] = [1, 2, 3]
      end
    end
  end

  def p24 do
    quote do
      defcore pred24() do
        [X, Y, Z, T] = [1, 2, 3]
      end
    end
  end

  def p25 do
    quote do
      defcore pred25(X) do
        X = [[1, 2, 3]]
      end
    end
  end

  def p26 do
    quote do
      defcore pred26() do
        @(g(3, 4))
      end
    end
  end

  def p27 do
    quote do
      defcore pred27() do
        @(3)
      end
    end
  end

  def p28 do
    quote do
      defcore pred28(X) do
        X = 3
        @(X + 4)
      end
    end
  end

  def p29 do
    quote do
      defcore pred29(X) do
        X = [1 | []]
      end
    end
  end

  def p30 do
    quote do
      defcore pred30(X) do
        X = [1 | [2]]
      end
    end
  end

  def p301 do
    quote do
      defcore pred30(X) do
        X = [1 | [2 | []]]
      end
    end
  end

  def p31 do
    quote do
      defcore pred31(X, Y) do
        X = 1
        Y = [X | [2 | [3 |[]]]]
      end
    end
  end

  def p32 do
    quote do
      defcore is_ordered(Xs) do
        choice do
          Xs = []
        else
          Xs = [X | []]
        else
          Xs = [X | [Y | [Ys]]]
          @(X <= Y)
          is_ordered([Y | [Ys]])
        end
      end
    end
  end

  def p320 do
    quote do
      defcore p320(X) do
        choice do
          X = []
        else
          X = [Y | []]
        else
          X = [Y | [Z | [T]]]
          @(Y < Z)
        # else
        #   X = [Y | [Z]]
        end
      end
    end
  end

  def p33 do
    quote do
      defcore pred33(X, Y, Z, T) do
        X = [Y | [Z | [T]]]
      end
    end
  end

  #####################
  # Private Functions #
  #####################

  defp vars(goals) when is_list(goals) do
    goals
    |> Enum.map(fn goal -> vars(goal) end)
    |> :lists.flatten()
    |> Enum.filter(fn arg -> is_logic_variable?(arg) end)
    |> Enum.uniq()
    |> Enum.map(fn {:__aliases__, _metadata, [logic_variable]} -> logic_variable end)
  end

  defp vars({:=, _metadata, [t1, t2]}) do
    terms1 = flat_terms(t1)
    terms2 = flat_terms(t2)
    [terms1, terms2]
  end

  defp vars({:choice, [], [choice_block]}) do
    choice_vars(choice_block)
  end

  defp vars({:__block__, [], block}) do
    vars(block) |> List.flatten()
  end

  defp vars({:@, _metadata, at_arguments}), do: flat_terms(at_arguments)

  defp vars({_predicate_name, _metadata, arguments}), do: flat_terms(arguments)

  defp vars(_) do
    []
  end

  defp flat_terms({:__aliases__, _metadata, [logic_variable]} = term) when is_atom(logic_variable), do: term
  defp flat_terms(terms) when is_tuple(terms), do: Tuple.to_list(terms)
  defp flat_terms([{:|, [], terms}]), do: flat_pipe_terms(terms)
  defp flat_terms(terms) when is_list(terms), do: terms
  defp flat_terms(terms), do: terms

  defp flat_pipe_terms([t1, t2]) do
    ts = case t2 do
      [] -> []
      [{:|, [], terms}] -> flat_pipe_terms(terms)
      _ -> t2
    end
    [t1, ts]
  end

  defp choice_vars([{:do, do_block}, {:else, else_block} | rest]) do
    do_block_vars = vars(do_block)
    else_block_vars = vars(else_block)
    result = case rest do
      [] -> [do_block_vars, else_block_vars]
      _ ->
        rest_block_vars =
          rest
          |> Enum.map(fn {:else, extra_else_block} ->
            vars(extra_else_block)
          end)
        [do_block_vars, else_block_vars, rest_block_vars]
    end
    result
  end

  defp choice_goals(delta, [{:do, do_block}, {:else, else_block} | rest]) do
    do_block_list =
      case do_block do
        {:__block__, [], do_list} -> do_list
        _ -> [do_block]
      end

    else_block_list =
      case else_block do
        {:__block__, [], else_list} -> else_list
        _ -> [else_block]
      end

    goals =
      case rest do
        [] ->
          [do_block_list, else_block_list]

        _ ->
          rest_list =
            rest
            |> Enum.map(fn {:else, extra_else_block} ->
              case extra_else_block do
                {:__block__, [], else_list} -> else_list
                _ -> [extra_else_block]
              end
            end)
            |> :lists.flatten()

          [do_block_list, else_block_list, rest_list]
      end

    goals
    |> Enum.map(fn goals -> tr_goals(delta, goals) end)
  end

  defp is_logic_variable?({:__aliases__, _metadata, [logic_variable]})
       when is_atom(logic_variable),
       do: true

  defp is_logic_variable?(term) when is_atom(term) do
    string_term = Atom.to_string(term)
    string_term == String.upcase(string_term)
  end

  defp is_logic_variable?(_), do: false
end

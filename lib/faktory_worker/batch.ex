defmodule FaktoryWorker.Batch do
  @moduledoc """
  Supports Faktory Batch operations

  [Batch support](https://github.com/contribsys/faktory/wiki/Ent-Batches) is a
  Faktory Enterprise feature. It allows jobs to pushed as part of a batch. When
  all jobs in a batch have completed, Faktory will queue a callback job. This
  allows building complex job workflows with dependencies.

  Jobs pushed as part of a batch _must_ be pushed synchronously. This can be
  done using the `skip_pipeline: true` option when calling `perform_async/2`. If
  a job isn't pushed synchronously, you may encounter a race condition where the
  batch is committed before all jobs have been pushed.

  ## Creating a batch

  A batch is created using `new!/2` and must provide a description and declare
  one of the success or complete callbacks. The `new!/2` function returns the
  batch ID (or `bid`) which identifies the batch for future commands.

  Once created, jobs can be pushed to the batch by providing the `bid` in the
  `custom` payload. These jobs must be pushed synchronously.

  ```
  alias FaktoryWorker.Batch

  {:ok, bid} = Batch.new!("Complex work batch", on_success: {MyApp.EmailReportJob, [], []})
  MyApp.Job.perform_async([1, 2], custom: %{"bid" => bid}, skip_pipeline: true)
  MyApp.Job.perform_async([3, 4], custom: %{"bid" => bid}, skip_pipeline: true)
  MyApp.Job.perform_async([5, 6], custom: %{"bid" => bid}, skip_pipeline: true)
  Batch.commit(bid)
  ```

  ## Opening a batch

  In order to open a batch, you must know the batch ID. Since FaktoryWorker
  doesn't currently pass the job itself as a parameter to `perform` functions,
  you must explicitly pass it as an argument in order to open the batch as part
  of a job.

  ```
  defmodule MyApp.Job do
    use FaktoryWorker.Job

    def perform(arg1, arg2, bid) do
      Batch.open(bid)

      MyApp.OtherJob.perform_async([1, 2], custom: %{"bid" => bid}, skip_pipeline: true)

      Batch.commit(bid)
    end
  end
  ```

  """
  alias FaktoryWorker.{ConnectionManager, Job, Pool}

  @type bid :: String.t()

  @default_timeout 5000

  @doc """
  Creates a new Faktory batch

  Takes the description of the batch job, a string, and the options necessary to
  create the batch job.

  Returns the batch ID (`bid`) which needs to be passed in the `:custom`
  parameters of every job that should be part of this batch as well as to commit
  the batch.

  ## Opts

  Batch jobs must define a success or complete callback (or both). These
  callbacks are passed as tuples to the `:on_success` and `:on_complete` opts.
  They are defined as a tuple consisting of `{mod, args, opts}` where `mod` is a
  module with a `perform` function that corresponds in arity to the length of `args`.

  Any `opts` that can be passed to `perform_async/2` can be provided as `opts`
  to the callback except for `:faktory_worker`.

  If neither callback is provided, an error will be raised.

  ### `:on_success`

  See above.

  ### `:on_complete`

  See above.

  ### `:parent_bid`

  The parent batch ID--only used if you are creating a child batch.

  ### `:faktory_worker`

  The name of the `FaktoryWorker` instance (determines which connection pool
  will be used).
  """
  @spec new!(String.t(), Keyword.t()) :: {:ok, bid()}
  def new!(description, opts \\ []) do
    success = Keyword.get(opts, :on_success)
    complete = Keyword.get(opts, :on_complete)
    bid = Keyword.get(opts, :parent_id)

    payload =
      %{description: description}
      |> maybe_put_parent_id(bid)
      |> maybe_put_callback(:success, success)
      |> maybe_put_callback(:complete, complete)
      |> validate!()

    send_command({:batch_new, payload}, opts)
  end

  @doc """
  Commits the batch identified by `bid`

  Faktory will begin scheduling jobs that are part of the batch before the batch
  is committed, but
  """
  def commit(bid, opts \\ []) do
    send_command({:batch_commit, bid}, opts)
  end

  @doc """
  Opens the batch identified by `bid`

  An existing batch needs to be re-opened in order to add more jobs to it or to
  add a child batch.

  After opening the batch, it must be committed again using `commit/2`.
  """
  def open(bid, opts \\ []) do
    send_command({:batch_open, bid}, opts)
  end

  @doc """
  Gets the status of a batch

  Returns a map representing the status
  """
  def status(bid, opts \\ []) do
    send_command({:batch_status, bid}, opts)
  end

  defp send_command(command, opts) do
    opts
    |> Keyword.get(:faktory_name, FaktoryWorker)
    |> Pool.format_pool_name()
    |> :poolboy.transaction(
      &ConnectionManager.Server.send_command(&1, command),
      @default_timeout
    )
  end

  defp maybe_put_parent_id(payload, nil), do: payload
  defp maybe_put_parent_id(payload, bid), do: Map.put_new(payload, :parent_bid, bid)

  defp maybe_put_callback(payload, _type, nil), do: payload

  defp maybe_put_callback(payload, type, {mod, job, opts}) do
    job_payload = Job.build_payload(mod, job, opts)

    Map.put_new(payload, type, job_payload)
  end

  defp validate!(payload) do
    success = Map.get(payload, :success)
    complete = Map.get(payload, :complete)

    case {success, complete} do
      {nil, nil} ->
        raise("Faktory batch jobs must declare a success or complete callback")

      {_, _} ->
        payload
    end
  end
end

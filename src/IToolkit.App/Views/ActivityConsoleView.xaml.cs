namespace IToolkit.App.Views;

using System.Windows.Controls;
using IToolkit.App.ViewModels;

public partial class ActivityConsoleView : UserControl
{
    public ActivityConsoleView()
    {
        InitializeComponent();
        DataContextChanged += OnDataContextChanged;
    }

    private void OnDataContextChanged(object sender, System.Windows.DependencyPropertyChangedEventArgs e)
    {
        if (e.OldValue is ActivityConsoleViewModel oldVm)
        {
            oldVm.LogEntryAppended -= OnLogEntryAppended;
        }

        if (e.NewValue is ActivityConsoleViewModel newVm)
        {
            newVm.LogEntryAppended += OnLogEntryAppended;
        }
    }

    private void OnLogEntryAppended()
    {
        if (DataContext is ActivityConsoleViewModel vm && vm.AutoScroll && LogListBox.Items.Count > 0)
        {
            LogListBox.ScrollIntoView(LogListBox.Items[^1]);
        }
    }
}

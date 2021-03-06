let
    #"Date Range List" = List.Generate(()=>14, each _ > 0,each _ -1 , each Date.AddMonths(DateTime.LocalNow(),-_+1)),
    #"Date Range List: formatting" = List.Transform(#"Date Range List", each Text.From(Date.Year(_))&"-"&Text.PadStart(Text.From(Date.Month(_)),2,"0")),
    #"Converted to Table" = Table.FromList(#"Date Range List: formatting", Splitter.SplitByNothing(), null, null, ExtraValues.Error),
    #"Invoked Custom Function" = Table.AddColumn(#"Converted to Table", "Data", each getEAUsageData([Column1])),
    #"Renamed Columns" = Table.RenameColumns(#"Invoked Custom Function",{{"Column1", "Name"}}), 
    //we're going to store the data column in a temporary variable
    #"Data: Content" = Table.Column(#"Renamed Columns", "Data"),
    //we're looping over all tables to get a list of all columnnames
    #"Data: ColumNames" = List.Distinct(List.Combine(List.Transform(#"Data: Content", 
                        each Table.ColumnNames(_)))),
    //using the list of columnnames we can now expand the data
    #"Data: Expanded Data" = Table.ExpandTableColumn(#"Renamed Columns", "Data",#"Data: ColumNames",#"Data: ColumNames"),
    //the line below is an alternative approach. This is the code that is generated by clicking the expand button on a column. 
    //#"Data: Expanded Data" = Table.ExpandTableColumn(#"Setup: Filtered Rows", "Data", {"AccountOwnerId", "Account Name", "ServiceAdministratorId", "SubscriptionId", "SubscriptionGuid", "Subscription Name", "Date", "Month", "Day", "Year", "Product", "Meter ID", "Meter Category", "Meter Sub-Category", "Meter Region", "Meter Name", "Consumed Quantity", "ResourceRate", "ExtendedCost", "Resource Location", "Consumed Service", "Instance ID", "ServiceInfo1", "ServiceInfo2", "AdditionalInfo", "Tags", "Store Service Identifier", "Department Name", "Cost Center", "Unit Of Measure", "Resource Group", ""}, {"AccountOwnerId", "Account Name", "ServiceAdministratorId", "SubscriptionId", "SubscriptionGuid", "Subscription Name", "Date", "Month", "Day", "Year", "Product", "Meter ID", "Meter Category", "Meter Sub-Category", "Meter Region", "Meter Name", "Consumed Quantity", "ResourceRate", "ExtendedCost", "Resource Location", "Consumed Service", "Instance ID", "ServiceInfo1", "ServiceInfo2", "AdditionalInfo", "Tags", "Store Service Identifier", "Department Name", "Cost Center", "Unit Of Measure", "Resource Group", ""}),
    //we only need to change the type for non-text columns
    #"Setup: Changed Type Localized" = Table.TransformColumnTypes(#"Data: Expanded Data",{{"SubscriptionId", Int64.Type}, {"Month", Int64.Type}, {"Day", Int64.Type}, {"Year", Int64.Type}, {"Consumed Quantity", type number}, {"ResourceRate", type number},{"Date", type date},{"ExtendedCost", type number}},"en-US"),
    // in some cases we end up with some empty rows, we only want to keep the rows with actual data (e.g. subscription guid being present)
    #"Setup: Filter Empty Rows" = Table.SelectRows(#"Setup: Changed Type Localized", each [SubscriptionGuid] <> null),    
    //further down we'll expand the Tags column. In order to keep the original column we'll take a copy of it first
    #"Tags: Duplicated Column" = Table.DuplicateColumn(#"Setup: Filter Empty Rows", "Tags", "Tags - Copy"),
    //We need to pouplate the empty json tag {} for values that are blank
    #"Tags: Replace Empty Value" = Table.ReplaceValue(#"Tags: Duplicated Column","","{}",Replacer.ReplaceValue,{"Tags - Copy"}),
    //sometimes tags might have different casings due to erroneous input (e.g. Environment and environment). Here we convert them to Proper casing
    #"Tags: Capitalized Each Word" = Table.TransformColumns(#"Tags: Replace Empty Value",{{"Tags - Copy", Text.Proper}}),    
    //convert the content of the Tags column to JSON records
    #"Tags: in JSON" = Table.TransformColumns(#"Tags: Capitalized Each Word",{{"Tags - Copy", Json.Document}}),
    //The next steps will determine a list of columns that need to be added and populated
    //the idea is to have a column for each tag key type
    //take the Tags column in a temp list variable
    //source of inspiration: https://blog.crossjoin.co.uk/2014/05/21/expanding-all-columns-in-a-table-in-power-query/
    #"Tags: Content" = Table.Column(#"Tags: in JSON", "Tags - Copy"),
    //for each of the Tags: take the fieldnames (key names) and add them to a list while removing duplicates
    #"Tags: FieldNames" = List.Distinct(List.Combine(List.Transform(#"Tags: Content", 
                        each Record.FieldNames(_)))),
    //sometimes EA Usage Data contains a lot of hidden tags. For now I don't know where they are comming from
    //this results in a massive amount of columns. For now I'm just filtering them
    //Examples: "Hidden-Related:/Subscription/…" or "Hidden-Devtestlabs-Labid..."
    #"Tags: Filtered FieldNames" = List.Select(#"Tags: FieldNames", each not Text.StartsWith(_,"Hidden-")),
    //this is the list of the actual column names. We're prepending Tag.'
    #"Tags: New Column Names" = List.Transform(#"Tags: Filtered FieldNames", each "Tag." & _),    
    //expand the JSON records using the fieldnames (keys) to new column names list mapping
    #"Tags: Expanded" = Table.ExpandRecordColumn(#"Tags: in JSON", "Tags - Copy", #"Tags: Filtered FieldNames",#"Tags: New Column Names"),
    //create a column with the consumption date (instead of 3 separate columns)    
    #"Consumption Date: Added Column" = Table.AddColumn(#"Tags: Expanded", "ConsumptionDate", each Text.From([Month])&"/"&Text.From([Day])&"/"&Text.From([Year])),
    #"Consumption Date: Change to Date Type" = Table.TransformColumnTypes(#"Consumption Date: Added Column",{{"ConsumptionDate", type date}},"en-US"),
    //create a column with the amount of days ago the usage happened
    #"Date Difference: Added Column" = Table.AddColumn(#"Consumption Date: Change to Date Type", "DateDifference", each Duration.Days(Duration.From(DateTime.Date(DateTime.LocalNow())- [ConsumptionDate]))),
    #"Date Difference: Changed to Number Type" = Table.TransformColumnTypes(#"Date Difference: Added Column",{{"DateDifference", type number}}),
    //create a friendly name for resource (as an alternative to the instance ID which is quite long)
    #"Resource Name: Duplicate Instance ID" = Table.DuplicateColumn(#"Date Difference: Changed to Number Type", "Instance ID", "Instance ID-TEMP"),
    #"Resource Name: Split Column" = Table.SplitColumn(#"Resource Name: Duplicate Instance ID","Instance ID-TEMP",Splitter.SplitTextByEachDelimiter({"/"}, QuoteStyle.Csv, true),{"Instance ID.1", "Instance ID.2"}),
    #"Resource Name: Construct Column" = Table.AddColumn(#"Resource Name: Split Column", "Resource Name", each if [Instance ID.2] = null then [Instance ID.1] else [Instance ID.2] ),
    #"Cleanup: Removed Undesired Columns" = Table.RemoveColumns(#"Resource Name: Construct Column",{"Instance ID.1", "Instance ID.2", "AccountOwnerId", "Account Name", "ServiceAdministratorId"})
in
    #"Cleanup: Removed Undesired Columns"
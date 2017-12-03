class GradesController < ApplicationController
  helper :file
  helper :submitted_content
  helper :penalty
  include PenaltyHelper
  include StudentTaskHelper
  protect_from_forgery

  def action_allowed?
    case params[:action]
    when 'view_my_scores'
        ['Instructor',
         'Teaching Assistant',
         'Administrator',
         'Super-Administrator',
         'Student'].include? current_role_name and 
        are_needed_authorizations_present?(params[:id], "reader", "reviewer") and 
        check_self_review_status
    when 'view_team'
        if ['Student'].include? current_role_name # students can only see the head map for their own team
          participant = AssignmentParticipant.find(params[:id])
          session[:user].id == participant.user_id
        else
          true
        end
      else
        ['Instructor',
         'Teaching Assistant',
         'Administrator',
         'Super-Administrator'].include? current_role_name
    end
  end

  # the view grading report provides the instructor with an overall view of all the grades for
  # an assignment. It lists all participants of an assignment and all the reviews they received.
  # It also gives a final score, which is an average of all the reviews and greatest difference
  # in the scores of all the reviews.
  def view
    @assignment = Assignment.find(params[:id])
    @id = params[:id]
    @questions = {}
    questionnaires = @assignment.questionnaires

    if @assignment.varying_rubrics_by_round?
      self.retrieve_questions(questionnaires)
    else # if this assignment does not have "varying rubric by rounds" feature
      questionnaires.each do |questionnaire|
        @questions[questionnaire.symbol] = questionnaire.questions
      end
    end

    @scores = @assignment.scores(@questions)
    averages = calculate_average_vector(@assignment.scores(@questions))
    @average_chart = bar_chart(averages, 1000, 150, 5)
    @avg_of_avg = mean(averages)
    calculate_all_penalties(@assignment.id)

    if @assignment.varying_rubrics_by_round?
      @authors, @all_review_response_ids_round_one, @all_review_response_ids_round_two, @all_review_response_ids_round_three =
        FeedbackResponseMap.feedback_response_report(@id, "FeedbackResponseMap")
    else
      @authors, @all_review_response_ids = FeedbackResponseMap.feedback_response_report(@id, "FeedbackResponseMap")
    end

    # private functions for generating a valid highchart
    min, max, number_of_review_questions = calculate_review_questions(@assignment, questionnaires)
    team_data = get_team_data(@assignment, questionnaires, @scores)
    highchart_data = get_highchart_data(team_data, @assignment, min, max, number_of_review_questions)
    @highchart_series_data, @highchart_categories, @highchart_colors = generate_highchart(highchart_data, min, max, number_of_review_questions,@assignment, team_data)
  end

  # This method is used to retrieve questions for different review rounds
  def retrieve_questions(questionnaires)
    questionnaires.each do |questionnaire|
      round = AssignmentQuestionnaire.where(assignment_id: @assignment.id, questionnaire_id: questionnaire.id).first.used_in_round
      questionnaire_symbol = if (!round.nil?)
        (questionnaire.symbol.to_s+round.to_s).to_sym
      else
        questionnaire.symbol
                             end
      @questions[questionnaire_symbol] = questionnaire.questions
    end
  end

  def view_my_scores
    @participant = AssignmentParticipant.find(params[:id])
    @team_id = TeamsUser.team_id(@participant.parent_id, @participant.user_id)
    return if redirect_when_disallowed
    @assignment = @participant.assignment
    @questions = {} # A hash containing all the questions in all the questionnaires used in this assignment
    questionnaires = @assignment.questionnaires
    retrieve_questions questionnaires

    # @pscore has the newest versions of response for each response map, and only one for each response map (unless it is vary rubric by round)
    @pscore = @participant.scores(@questions)
    make_chart
    @topic_id = SignedUpTeam.topic_id(@participant.assignment.id, @participant.user_id)
    @stage = @participant.assignment.get_current_stage(@topic_id)
    calculate_all_penalties(@assignment.id)

    # prepare feedback summaries
    summary_ws_url = WEBSERVICE_CONFIG["summary_webservice_url"]
    sum = SummaryHelper::Summary.new.summarize_reviews_by_reviewee(@questions, @assignment, @team_id, summary_ws_url)

    @summary = sum.summary
    @avg_scores_by_round = sum.avg_scores_by_round
    @avg_scores_by_criterion = sum.avg_scores_by_criterion
  end

  def view_team
    # get participant, team, questionnaires for assignment.
    @participant = AssignmentParticipant.find(params[:id])
    @assignment = @participant.assignment
    @team = @participant.team
    @team_id = @team.id

    questionnaires = @assignment.questionnaires
    @vmlist = []

    # loop through each questionnaire, and populate the view model for all data necessary
    # to render the html tables.
    questionnaires.each do |questionnaire|
      @round = if @assignment.varying_rubrics_by_round? && questionnaire.type == "ReviewQuestionnaire"
        AssignmentQuestionnaire.find_by_assignment_id_and_questionnaire_id(@assignment.id, questionnaire.id).used_in_round
      else
        nil
               end

      vm = VmQuestionResponse.new(questionnaire, @round, @assignment.rounds_of_reviews)
      questions = questionnaire.questions
      vm.add_questions(questions)
      vm.add_team_members(@team)
      vm.add_reviews(@participant, @team, @assignment.varying_rubrics_by_round?)
      vm.get_number_of_comments_greater_than_10_words

      @vmlist << vm
    end
    @current_role_name = current_role_name
  end

  def edit
    @participant = AssignmentParticipant.find(params[:id])
    @assignment = @participant.assignment

    list_questions @assignment

    @scores = @participant.scores(@questions)
  end

  def instructor_review
    participant = AssignmentParticipant.find(params[:id])

    reviewer = AssignmentParticipant.where(user_id: session[:user].id, parent_id:  participant.assignment.id).first
    if reviewer.nil?
      reviewer = AssignmentParticipant.create(user_id: session[:user].id, parent_id: participant.assignment.id)
      reviewer.set_handle
    end

    review_exists = true

    if participant.assignment.team_assignment?
      reviewee = participant.team
      review_mapping = ReviewResponseMap.where(reviewee_id: reviewee.id, reviewer_id:  reviewer.id).first

      if review_mapping.nil?
        review_exists = false
        review_mapping = ReviewResponseMap.create(reviewee_id: participant.team.id, reviewer_id: reviewer.id, reviewed_object_id: participant.assignment.id)
        review = Response.find_by_map_id(review_mapping.map_id)

        unless review_exists
          redirect_to controller: 'response', action: 'new', id: review_mapping.map_id, return: "instructor"
        else
          redirect_to controller: 'response', action: 'edit', id: review.id, return: "instructor"
        end
      end
    end
  end

  def open
    send_file(params['fname'], disposition: 'inline')
  end

  # This method is used from edit methods
  def list_questions(assignment)
    @questions = {}
    questionnaires = assignment.questionnaires
    questionnaires.each do |questionnaire|
      @questions[questionnaire.symbol] = questionnaire.questions
    end
  end

  def update
    participant = AssignmentParticipant.find(params[:id])
    total_score = params[:total_score]
    if sprintf("%.2f", total_score) != params[:participant][:grade]
      participant.update_attribute(:grade, params[:participant][:grade])
      message = if participant.grade.nil?
        "The computed score will be used for "+participant.user.name+"."
      else
        "A score of "+params[:participant][:grade]+"% has been saved for "+participant.user.name+"."
                end
    end
    flash[:note] = message
    redirect_to action: 'edit', id: params[:id]
  end

  def save_grade_and_comment_for_submission
    participant = AssignmentParticipant.find(params[:participant_id])
    @team = participant.team
    @team.grade_for_submission = params[:grade_for_submission]
    @team.comment_for_submission = params[:comment_for_submission]
    begin
      @team.save
    rescue
      flash[:error] = $ERROR_INFO
    end
    redirect_to controller: 'grades', action: 'view_team', id: params[:participant_id]
  end

  private

  def redirect_when_disallowed
    # For author feedback, participants need to be able to read feedback submitted by other teammates.
    # If response is anything but author feedback, only the person who wrote feedback should be able to see it.
    ## This following code was cloned from response_controller.

    # ACS Check if team count is more than 1 instead of checking if it is a team assignment
    if @participant.assignment.max_team_size > 1
      team = @participant.team
      unless team.nil?
        unless team.has_user session[:user]
          redirect_to '/denied?reason=You are not on the team that wrote this feedback'
          return true
        end
      end
    else
      reviewer = AssignmentParticipant.where(user_id: session[:user].id, parent_id: @participant.assignment.id).first
      return true unless current_user_id?(reviewer.try(:user_id))
    end
    false
  end

  def get_body_text(submission)
    if submission
      role = "reviewer"
      item = "submission"
    else
      role = "metareviewer"
      item = "review"
    end
    "Hi ##[recipient_name],
        You submitted a score of ##[recipients_grade] for assignment ##[assignment_name] that varied greatly from another " + role + "'s score for the same " + item + ".
        The Expertiza system has brought this to my attention."
  end

  def calculate_review_questions(assignment, questionnaires)
    min = 0
    max = 5

    number_of_review_questions = 0
    questionnaires.each do |questionnaire|
      next unless assignment.varying_rubrics_by_round? && questionnaire.type == "ReviewQuestionnaire" # WHAT ABOUT NOT VARYING RUBRICS?
      number_of_review_questions = questionnaire.questions.size
      min = questionnaire.min_question_score < min ? questionnaire.min_question_score : min
      max = questionnaire.max_question_score > max ? questionnaire.max_question_score : max
      break
    end
    [min, max, number_of_review_questions]
  end

  def calculate_all_penalties(assignment_id)
    @all_penalties = {}
    @assignment = Assignment.find(assignment_id)
    calculate_for_participants = true unless @assignment.is_penalty_calculated
    Participant.where(parent_id: assignment_id).each do |participant|
      penalties = calculate_penalty(participant.id)
      @total_penalty = 0

      unless (penalties[:submission].zero? || penalties[:review].zero? || penalties[:meta_review].zero?)

        @total_penalty = (penalties[:submission] + penalties[:review] + penalties[:meta_review])
        l_policy = LatePolicy.find(@assignment.late_policy_id)
        if (@total_penalty > l_policy.max_penalty)
          @total_penalty = l_policy.max_penalty
        end
        calculate_penatly_attributes(@participant) if calculate_for_participants
      end
      assign_all_penalties(participant, penalties)
    end
    unless @assignment.is_penalty_calculated
      @assignment.update_attribute(:is_penalty_calculated, true)
    end
  end

  def calculate_penatly_attributes(_participant)
    penalty_attr1 = {deadline_type_id: 1, participant_id: @participant.id, penalty_points: penalties[:submission]}
    CalculatedPenalty.create(penalty_attr1)

    penalty_attr2 = {deadline_type_id: 2, participant_id: @participant.id, penalty_points: penalties[:review]}
    CalculatedPenalty.create(penalty_attr2)

    penalty_attr3 = {deadline_type_id: 5, participant_id: @participant.id, penalty_points: penalties[:meta_review]}
    CalculatedPenalty.create(penalty_attr3)
  end

  def assign_all_penalties(participant, penalties)
    @all_penalties[participant.id] = {}
    @all_penalties[participant.id][:submission] = penalties[:submission]
    @all_penalties[participant.id][:review] = penalties[:review]
    @all_penalties[participant.id][:meta_review] = penalties[:meta_review]
    @all_penalties[participant.id][:total_penalty] = @total_penalty
  end

  def make_chart
    @grades_bar_charts = {}
    if @pscore[:review]
      scores = []
      if @assignment.varying_rubrics_by_round?
        for round in 1..@assignment.rounds_of_reviews
          responses = @pscore[:review][:assessments].reject {|response| response.round != round }
          scores = scores.concat(get_scores_for_chart(responses, 'review' + round.to_s))
          scores -= [-1.0]
        end
        @grades_bar_charts[:review] = bar_chart(scores)
      else
        scores = get_scores_for_chart @pscore[:review][:assessments], 'review'
        scores -= [-1.0]
        @grades_bar_charts[:review] = bar_chart(scores)
      end

    end

    if @pscore[:metareview]
      scores = get_scores_for_chart @pscore[:metareview][:assessments], 'metareview'
      scores -= [-1.0]
      @grades_bar_charts[:metareview] = bar_chart(scores)
    end

    if @pscore[:feedback]
      scores = get_scores_for_chart @pscore[:feedback][:assessments], 'feedback'
      scores -= [-1.0]
      @grades_bar_charts[:feedback] = bar_chart(scores)
    end

    if @pscore[:teammate]
      scores = get_scores_for_chart @pscore[:teammate][:assessments], 'teammate'
      scores -= [-1.0]
      @grades_bar_charts[:teammate] = bar_chart(scores)

    end
  end

  def get_scores_for_chart(reviews, symbol)
    scores = []
    reviews.each do |review|
      scores << Answer.get_total_score(response: [review], questions: @questions[symbol.to_sym], q_types: [])
    end
    scores
  end

  def calculate_average_vector(scores)
    scores[:teams].reject! {|_k, v| v[:scores][:avg].nil? }
    scores[:teams].map {|_k, v| v[:scores][:avg].to_i }
  end

  def bar_chart(scores, width = 100, height = 100, spacing = 1)
    link = nil
    GoogleChart::BarChart.new("#{width}x#{height}", " ", :vertical, false) do |bc|
      data = scores
      bc.data "Line green", data, '990000'
      bc.axis :y, range: [0, data.max], positions: [data.min, data.max]
      bc.show_legend = false
      bc.stacked = false
      bc.width_spacing_options(bar_width: (width - 30) / (data.size + 1), bar_spacing: 1, group_spacing: spacing)
      bc.data_encoding = :extended
      link = bc.to_url
    end
    link
  end

  def get_team_data(assignment, questionnaires, scores)
    team_data = []
    for index in 0..scores[:teams].length - 1
      participant = AssignmentParticipant.find(scores[:teams][index.to_s.to_sym][:team].participants.first.id)
      team = participant.team
      vmlist = []

      questionnaires.each do |questionnaire|
        round = if assignment.varying_rubrics_by_round? && questionnaire.type == "ReviewQuestionnaire"
                  AssignmentQuestionnaire.find_by(assignment_id: assignment.id, questionnaire_id: questionnaire.id).used_in_round
                else
                  nil
                end

        vm = VmQuestionResponse.new(questionnaire, round, assignment.rounds_of_reviews)
        questions = questionnaire.questions
        vm.add_questions(questions)
        vm.add_team_members(team)
        vm.add_reviews(participant, team, assignment.varying_rubrics_by_round?)
        vm.get_number_of_comments_greater_than_10_words

        vmlist << vm
      end
      team_data << vmlist
    end
    team_data
  end

  def get_highchart_data(team_data, assignment, min, max, number_of_review_questions)
    chart_data = {}  # @chart_data is supposed to hold the general information for creating the highchart stack charts

    # Dynamic initialization
    #for i in 1..assignment.rounds_of_reviews
    #  chart_data[i] = Hash[(min..max).map {|score| [score, Array.new(number_of_review_questions, 0)] }]
    #end
    for i in 1..number_of_review_questions
      chart_data[i] = Hash[(min..max).map {|score| [score, Array.new(assignment.rounds_of_reviews, 0)] }]
    end

    # Dynamically filling @chart_data with values (For each team, their score to each rubric in the related submission
    # round will be added to the count in the corresponded array field)
    team_data.each do |team|
      team.each do |vm|
        next if vm.round.nil?
        j = 1
        vm.list_of_rows.each do |row|
          row.score_row.each do |score|
            unless score.score_value.nil?
              #chart_data[vm.round][score.score_value][j] += 1
              chart_data[j][score.score_value][vm.round-1] += 1
            end
          end
          j += 1
        end
      end
    end
    chart_data
  end

  def generate_highchart(chart_data, min, max, number_of_review_questions, assignment, team_data)
    # Here we actually build the 'series' array which will be used directly in the highchart Object in the _team_charts view file
    # This array holds the actual data of our chart with legend name
    highchart_series_data = []
    #chart_data.each do |round, scores|
    #  scores.to_a.reverse.to_h.each do |score, rubric_distribution|
    #    highchart_series_data.push(name: "Score #{score} - Submission #{round}", data: rubric_distribution, stack: "S#{round}")
    #  end
    #end
    rd = 0
    chart_data.each do |round, scores|
      scores.to_a.reverse.to_h.each do |score, rubric_distribution|
        if rd == 0
          highchart_series_data.push(name: "Score #{score}", data: rubric_distribution, stack: "S#{round}")
        else
          highchart_series_data.push(linkedTo: "previous",name: "Rubric #{round} - Score #{score}", data: rubric_distribution, stack: "S#{round}")
        end

      end
      rd = rd + 1
    end

    # Here we dynamically creates the categories which will be used later in the highchart Object
    highchart_categories = []
    for i in 1..@assignment.rounds_of_reviews
      highchart_categories.push("Submission #{i}")
    end

    # Here we dynamically creates an array of the colors which the highchart uses to show the stack charts and rotate on
    # Currently we create 6 different colors based on the assumption that we always have scores from 0 to 5
    # Future Works: Maybe adding the minimum score and maximum score instead of the hard-coded 0..5 range
    highchart_colors = []
    highchart_colors.push("#2DE636")
    highchart_colors.push("#BCED91")
    highchart_colors.push("#FFEC8B")
    highchart_colors.push("#FD992D")
    highchart_colors.push("#ff8080")
    highchart_colors.push("#FD422D")

    #for _i in min..max
    #  highchart_colors.push("\##{sprintf('%06x', (rand * 0xffffff))}")
    #end
    red = 255
    green = 120
=begin
    if (max.odd? and min.even?) or (max.even? and min.odd?)
      for i in min..(max/2)
        highchart_colors.push("RGB(4,#{green}, 25)")
        green += 20
      end
      for i in (max/2 + 1)..max
        highchart_colors.push("RGB(#{red}, 30, 4)")
        red -= 20
      end
    end
    if (max.odd? and min.odd?) or (max.even? and min.even?)
      for i in min..(max/2)
        highchart_colors.push("RGB(4,#{green}, 25)")
        green += 20
      end
      highchart_colors.push("RGB(247, 153, 9)")
      for i in (max/2 + 2)..max
        highchart_colors.push("RGB(#{red}, 30, 4)")
        red -= 20
      end
    end
=end

    [highchart_series_data, highchart_categories, highchart_colors]
  end

  def check_self_review_status
    participant = Participant.find(params[:id])
    assignment = participant.try(:assignment)
    if assignment.try(:is_selfreview_enabled) and unsubmitted_self_review?(participant.try(:id))
      return false
    else
      return true
    end
  end

  def mean(array)
    array.inject(0) {|sum, x| sum += x } / array.size.to_f
  end

  def mean_and_standard_deviation(array)
    m = mean(array)
    variance = array.inject(0) {|variance, x| variance += (x - m)**2 }
    [m, Math.sqrt(variance/(array.size-1))]
  end
end
